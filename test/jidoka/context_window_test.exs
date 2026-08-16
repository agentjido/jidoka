defmodule Jidoka.ContextWindowTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.ContextWindow
  alias Jidoka.ContextWindow.Policy
  alias Jidoka.Runtime.Spine.Steps
  alias Jidoka.Session
  alias Jidoka.Session.Conversation
  alias Jidoka.Session.Data
  alias Jidoka.Turn

  test "projection removes oldest whole turns and keeps a complete tool exchange" do
    prefix = [Agent.Message.system("System contract")]

    transcript =
      turn("turn-1", "old user", "old answer") ++
        turn("turn-2", "middle user", "middle answer") ++
        tool_turn("turn-3") ++
        [Agent.Message.user("active user", request_id: "turn-4")]

    prompt = base_prompt()
    sizing_policy = Policy.new!(minimum_recent_turns: 1, output_reserve: 20)

    kept_messages = prefix ++ tool_turn("turn-3") ++ [List.last(transcript)]

    budget =
      prompt
      |> Map.put(:messages, Enum.map(kept_messages, &Agent.Message.to_map/1))
      |> ContextWindow.estimate_tokens(sizing_policy)

    policy = %Policy{sizing_policy | input_budget: budget}

    assert {:ok, projected, evidence} =
             ContextWindow.project(prompt, prefix, transcript, policy, "turn-4")

    assert ContextWindow.estimate_tokens(projected, policy) <= budget
    assert evidence.status == :compacted
    assert evidence.omitted_turn_ids == ["turn-1", "turn-2"]
    assert evidence.omitted_message_count == 4
    assert evidence.output_reserve == 20

    assert Enum.map(projected.messages, &{&1.role, Map.get(&1, :content)}) == [
             {:system, "System contract"},
             {:user, "tool user"},
             {:assistant, "tool call"},
             {:tool, "tool result"},
             {:assistant, "tool answer"},
             {:user, "active user"}
           ]

    assert {:ok, same_projected, same_evidence} =
             ContextWindow.project(prompt, prefix, transcript, policy, "turn-4")

    assert same_projected == projected
    assert same_evidence == evidence
    assert length(transcript) == 9
  end

  test "projection fails before a required active turn exceeds the input budget" do
    prefix = [Agent.Message.system("System contract")]
    transcript = [Agent.Message.user(String.duplicate("x", 200), request_id: "active")]
    policy = Policy.new!(input_budget: 1, minimum_recent_turns: 0)

    assert {:error, {:context_input_budget_exceeded, evidence}, overflow} =
             ContextWindow.project(base_prompt(), prefix, transcript, policy, "active")

    assert evidence.estimated_input_tokens_after > policy.input_budget
    assert overflow.status == :overflow
    assert overflow.omitted_turn_ids == []
  end

  test "large grouped transcripts keep one exact suffix without partial turns" do
    prefix = [Agent.Message.system("System contract")]
    transcript = Enum.flat_map(1..100, &turn("turn-#{&1}", "user #{&1}", "answer #{&1}"))
    kept = Enum.drop(transcript, 190)
    sizing_policy = Policy.new!(minimum_recent_turns: 0)

    budget =
      base_prompt()
      |> Map.put(:messages, Enum.map(prefix ++ kept, &Agent.Message.to_map/1))
      |> ContextWindow.estimate_tokens(sizing_policy)

    policy = %Policy{sizing_policy | input_budget: budget}

    assert {:ok, projected, evidence} =
             ContextWindow.project(base_prompt(), prefix, transcript, policy, "turn-100")

    assert evidence.turn_count_after == 5
    assert evidence.omitted_turn_ids == Enum.map(1..95, &"turn-#{&1}")

    assert Enum.map(tl(projected.messages), & &1.content) ==
             Enum.flat_map(96..100, &["user #{&1}", "answer #{&1}"])
  end

  test "policy derives input capacity from model context and output reserve" do
    spec =
      Agent.Spec.new!(
        id: "bounded-model",
        instructions: "Reply.",
        model: %{
          provider: :test,
          id: "bounded",
          limits: %{context: 1_000, input: 900, output: 200}
        },
        generation: %{params: %{max_tokens: 250}},
        runtime_defaults: %{context_policy: %{minimum_recent_turns: 3}}
      )

    assert {:ok, %Turn.Plan{context_policy: policy}} = Turn.Plan.new(spec)
    assert policy.input_budget == 750
    assert policy.output_reserve == 250
    assert policy.minimum_recent_turns == 3
  end

  test "policy uses the smallest finite declared model capacity" do
    spec =
      Agent.Spec.new!(
        id: "candidate-model-budgets",
        instructions: "Reply.",
        model: %{provider: :test, id: "base", limits: %{context: 2_000, input: 1_800}},
        generation: %{params: %{max_tokens: 100}}
      )

    candidates = [
      %{provider: :openai, id: "primary", limits: %{context: 1_000, input: 900}},
      %{provider: :anthropic, id: "fallback", limits: %{context: 400, input: 350}}
    ]

    assert {:ok, prepared} =
             Turn.Execution.prepare(spec, "Use the safe budget",
               llm: fn _intent, _journal, _context -> {:ok, %{type: :final, content: "ok"}} end,
               model_policy: [models: candidates]
             )

    assert Enum.map(prepared.plan.model_candidates, &Jidoka.Config.model_ref/1) == [
             "openai:primary",
             "anthropic:fallback"
           ]

    assert prepared.plan.context_policy.input_budget == 300
    assert prepared.plan.context_policy.output_reserve == 100
  end

  test "prompt assembly records compaction without changing the complete transcript" do
    spec =
      Agent.Spec.new!(
        id: "bounded-assembly",
        instructions: "Reply with evidence.",
        model: %{provider: :test, id: "model"},
        runtime_defaults: %{
          context_policy: %{
            input_budget: 180,
            output_reserve: 40,
            minimum_recent_turns: 1
          }
        }
      )

    plan = Turn.Plan.new!(spec)

    history =
      turn("turn-1", String.duplicate("old user ", 20), String.duplicate("old answer ", 20)) ++
        turn("turn-2", "recent user", "recent answer")

    request =
      Turn.Request.new!(
        input: "active user",
        request_id: "turn-3",
        agent_state: Agent.State.new!(messages: history)
      )

    state =
      Turn.State.new!(
        spec: spec,
        plan: plan,
        request: request,
        agent_state: request.agent_state
      )
      |> Steps.assemble_prompt()

    assert state.context_projection.status == :compacted
    assert state.context_projection.omitted_turn_ids == ["turn-1"]
    assert ContextWindow.estimate_tokens(state.prompt, plan.context_policy) <= 180

    assert Enum.map(state.agent_state.messages, & &1.request_id) == [
             "turn-1",
             "turn-1",
             "turn-2",
             "turn-2",
             "turn-3"
           ]

    assert Enum.map(state.events, & &1.event) == [
             :context_compacted,
             :prompt_assembled
           ]

    assert hd(state.events).data.omitted_digest == state.context_projection.omitted_digest
  end

  test "a session sends the bounded projection and commits the complete audit transcript" do
    spec = bounded_spec(180)
    first_answer = String.duplicate("old answer ", 40)

    history =
      turn("turn-1", "old user", first_answer) ++
        turn("turn-2", "recent user", "recent answer")

    conversation =
      Conversation.new!(
        agent_state: Agent.State.new!(messages: history),
        continuation_revision: 2,
        turn_count: 2,
        last_completed_request_id: "turn-2"
      )

    assert {:ok, %Data{} = initial} = Session.start(spec, "bounded-session")
    initial = %Data{initial | conversation: conversation}

    llm = fn intent, _journal, _context ->
      messages = intent.payload.prompt.messages
      refute Enum.any?(messages, &(Map.get(&1, :content) == first_answer))
      assert Enum.any?(messages, &(Map.get(&1, :content) == "recent answer"))
      assert Enum.any?(messages, &(Map.get(&1, :content) == "active user"))
      {:ok, %{type: :final, content: "active answer"}}
    end

    assert {:ok, completed, result} =
             Session.run(initial, "active user", request_id: "turn-3", llm: llm)

    assert result.metadata.debug.prompt.context_projection.status == :compacted
    assert result.metadata.debug.prompt.context_projection.omitted_turn_ids == ["turn-1"]

    assert Enum.map(completed.conversation.agent_state.messages, & &1.content) == [
             "old user",
             first_answer,
             "recent user",
             "recent answer",
             "active user",
             "active answer"
           ]
  end

  test "an overflow returns an error without calling the model" do
    spec = bounded_spec(1)
    assert {:ok, session} = Session.start(spec, "overflow-session")

    llm = fn _intent, _journal, _context -> flunk("overflow called the model") end

    assert {:error, {:context_input_budget_exceeded, evidence}} =
             Session.run(session, "required input", request_id: "overflow-turn", llm: llm)

    assert evidence.status == :overflow
    assert evidence.estimated_input_tokens_after > 1
  end

  defp base_prompt do
    %{
      model: "test:model",
      operations: [],
      result: nil,
      memory: nil,
      context: %{},
      generation: %{max_tokens: 20},
      loop_index: 0
    }
  end

  defp turn(request_id, user, assistant) do
    [
      Agent.Message.user(user, request_id: request_id),
      Agent.Message.assistant(assistant, request_id: request_id)
    ]
  end

  defp tool_turn(request_id) do
    [
      Agent.Message.user("tool user", request_id: request_id),
      Agent.Message.assistant("tool call", request_id: request_id),
      Agent.Message.tool("lookup", %{"value" => 1},
        request_id: request_id,
        content: "tool result"
      ),
      Agent.Message.assistant("tool answer", request_id: request_id)
    ]
  end

  defp bounded_spec(input_budget) do
    Agent.Spec.new!(
      id: "bounded-session-agent",
      instructions: "Reply with evidence.",
      model: %{provider: :test, id: "model"},
      runtime_defaults: %{
        context_policy: %{
          input_budget: input_budget,
          output_reserve: 40,
          minimum_recent_turns: 1
        }
      }
    )
  end
end
