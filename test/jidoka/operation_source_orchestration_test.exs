defmodule Jidoka.OperationSourceOrchestrationTest do
  use ExUnit.Case, async: false

  alias Jidoka.Agent
  alias Jidoka.Context
  alias Jidoka.Effect
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Handoff, as: HandoffSource
  alias Jidoka.Operation.Source.Subagent
  alias Jidoka.Turn

  defmodule SuccessfulChild do
    @moduledoc false

    def spec do
      Agent.Spec.new!(
        id: "successful_child",
        instructions: "Return a deterministic child result.",
        model: %{provider: :test, id: "model"}
      )
    end

    def run_turn(request, opts) do
      context = Keyword.fetch!(request, :context)
      send(context.data.test_pid, {:child_request, request, opts, context})

      {:ok,
       struct(Turn.Result,
         content: "child complete",
         value: %{answer: 42},
         agent_state: %Agent.State{
           operation_results: [
             Effect.OperationResult.new!(operation: "child_lookup", output: %{found: true})
           ]
         }
       )}
    end
  end

  defmodule ErrorChild do
    @moduledoc false

    def spec do
      Agent.Spec.new!(
        id: "error_child",
        instructions: "Return an error.",
        model: %{provider: :test, id: "model"}
      )
    end

    def run_turn(_request, _opts), do: {:error, :child_failed}
  end

  setup do
    conversation_id = "orchestration-#{System.unique_integer([:positive, :monotonic])}"
    on_exit(fn -> Jidoka.reset_handoff(conversation_id) end)
    {:ok, conversation_id: conversation_id}
  end

  test "handoff sources validate constructor settings" do
    assert HandoffSource.schema()

    assert {:ok, source} = HandoffSource.new(agent: SuccessfulChild, metadata: nil)
    assert source.name == "successful_child"
    assert source.target == :auto

    assert {:ok, %{operations: [operation]}} = Source.compile(source)
    assert operation.description =~ "Transfer future conversation ownership"

    assert {:error, {:invalid_handoff_module, "invalid"}} =
             HandoffSource.new(agent: "invalid")

    assert {:error, {:invalid_handoff_module, String, :missing_spec}} =
             HandoffSource.new(agent: String)

    assert {:error, {:invalid_handoff_module, MissingHandoffAgent, _reason}} =
             HandoffSource.new(agent: MissingHandoffAgent)

    assert {:error, {:invalid_handoff_name, "Bad Name"}} =
             HandoffSource.new(agent: SuccessfulChild, name: "Bad Name")

    assert {:error, {:invalid_handoff_name, 123}} =
             HandoffSource.new(agent: SuccessfulChild, name: 123)

    assert {:error, {:invalid_handoff_target, :invalid}} =
             HandoffSource.new(agent: SuccessfulChild, target: :invalid)

    assert {:error, {:invalid_handoff_forward_context, :invalid}} =
             HandoffSource.new(agent: SuccessfulChild, forward_context: :invalid)

    assert {:error, {:invalid_handoff_metadata, :invalid}} =
             HandoffSource.new(agent: SuccessfulChild, metadata: :invalid)

    assert_raise ArgumentError, ~r/invalid handoff source/, fn ->
      HandoffSource.new!(agent: "invalid")
    end
  end

  test "handoff capability supports static, context, and automatic peers", %{
    conversation_id: conversation_id
  } do
    base_data = %{
      "peer_id" => "peer-from-string",
      conversation_id: conversation_id,
      tenant: "acme",
      secret: "hidden",
      peer_id: "peer-from-context"
    }

    cases = [
      {:auto, :public, "#{conversation_id}:delegate",
       %{"peer_id" => "peer-from-string", tenant: "acme", secret: "hidden"}},
      {{:peer, "static-peer"}, :none, "static-peer", %{}},
      {{:peer, {:context, :peer_id}}, {:only, [:tenant, :missing]}, "peer-from-context", %{tenant: "acme"}},
      {{:peer, {:context, "peer_id"}}, {:except, [:secret, "peer_id"]}, "peer-from-string", %{tenant: "acme"}}
    ]

    Enum.each(cases, fn {target, forward_context, expected_peer, expected_context} ->
      source =
        HandoffSource.new!(
          agent: SuccessfulChild,
          name: :delegate,
          target: target,
          forward_context: forward_context
        )

      context = Context.from_data!(base_data, runtime: %{agent_module: :router})

      assert {:ok, %{handoff: handoff, owner: owner}} =
               invoke(source, %{message: " Delegate this. ", context: :invalid}, context)

      assert handoff.message == "Delegate this."
      assert handoff.to_agent_id == expected_peer
      assert Map.drop(handoff.context, [:conversation_id, :peer_id]) == expected_context
      assert owner.agent_id == expected_peer
    end)
  end

  test "handoff capability reports boundary and payload errors", %{conversation_id: conversation_id} do
    source = HandoffSource.new!(agent: SuccessfulChild, name: :delegate)
    context = Context.from_data!(%{conversation_id: conversation_id})
    {:ok, capability} = Source.capability(source)

    wrong_kind = Effect.Intent.new(:llm, %{})

    assert {:error, {:unsupported_effect_kind, :llm}} =
             capability.(wrong_kind, Effect.Journal.new!(), context)

    assert {:error, {:missing_operation_handler, "wrong"}} =
             invoke(source, %{message: "valid"}, context, "wrong")

    assert {:error, {:invalid_handoff_payload, :message}} =
             invoke(source, %{message: "   "}, context)

    assert {:error, {:invalid_handoff_payload, {:message, 123}}} =
             invoke(source, %{message: 123}, context)

    missing_peer =
      HandoffSource.new!(
        agent: SuccessfulChild,
        name: :delegate,
        target: {:peer, {:context, :missing}}
      )

    assert {:error, {:missing_handoff_peer_context, :missing}} =
             invoke(missing_peer, %{message: "valid"}, context)

    invalid_peer =
      HandoffSource.new!(agent: SuccessfulChild, name: :delegate, target: {:peer, ""})

    assert {:error, {:invalid_handoff_peer_id, ""}} =
             invoke(invalid_peer, %{message: "valid"}, context)
  end

  test "subagent sources validate settings and publish default operation data" do
    assert Subagent.schema()
    assert {:ok, source} = Subagent.new(agent: SuccessfulChild, metadata: nil)
    assert source.name == "successful_child"

    assert {:ok, %{operations: [operation]}} = Source.compile(source)
    assert operation.description =~ "Delegate one bounded task"

    assert {:error, {:invalid_subagent_module, "invalid"}} = Subagent.new(agent: "invalid")
    assert {:error, {:invalid_subagent_module, String, :missing_spec}} = Subagent.new(agent: String)

    assert {:error, {:invalid_subagent_module, MissingSubagent, _reason}} =
             Subagent.new(agent: MissingSubagent)

    assert {:error, {:invalid_subagent_name, "Bad Name"}} =
             Subagent.new(agent: SuccessfulChild, name: "Bad Name")

    assert {:error, {:invalid_subagent_name, 123}} =
             Subagent.new(agent: SuccessfulChild, name: 123)

    assert {:error, {:invalid_subagent_timeout, 0}} =
             Subagent.new(agent: SuccessfulChild, timeout: 0)

    assert {:error, {:invalid_subagent_forward_context, :invalid}} =
             Subagent.new(agent: SuccessfulChild, forward_context: :invalid)

    assert {:ok, %{result: :text}} = Subagent.new(agent: SuccessfulChild, result: "text")

    assert {:error, {:invalid_subagent_result, "invalid"}} =
             Subagent.new(agent: SuccessfulChild, result: "invalid")

    assert {:error, {:invalid_subagent_result, 123}} =
             Subagent.new(agent: SuccessfulChild, result: 123)

    assert {:error, {:invalid_subagent_metadata, :invalid}} =
             Subagent.new(agent: SuccessfulChild, metadata: :invalid)

    assert_raise ArgumentError, ~r/invalid subagent source/, fn ->
      Subagent.new!(agent: "invalid")
    end
  end

  test "subagent capability returns structured and text child results" do
    for {result_mode, expected} <- [structured: %{value: %{answer: 42}}, text: %{}] do
      source =
        Subagent.new!(
          agent: SuccessfulChild,
          name: :delegate,
          result: result_mode,
          forward_context: {:except, [:secret]}
        )

      context =
        Context.from_data!(
          %{test_pid: self(), tenant: "acme", secret: "hidden"},
          runtime: %{subagent_opts: :invalid, nested_resume_opts: :invalid}
        )

      assert {:ok, output} = invoke(source, %{task: " Do the work. ", context: %{local: true}}, context)
      assert output.content == "child complete"
      assert Map.take(output, Map.keys(expected)) == expected

      assert_receive {:child_request, request, opts, child_context}
      assert Keyword.fetch!(request, :input) == " Do the work. "
      assert child_context.data == %{test_pid: self(), tenant: "acme", local: true}
      assert Keyword.fetch!(opts, :timeout) == 30_000
    end
  end

  test "subagent capability reports unsupported, routing, task, and child errors" do
    source = Subagent.new!(agent: ErrorChild, name: :delegate, forward_context: :none)
    context = Context.from_data!(%{})
    {:ok, capability} = Source.capability(source)

    assert {:error, {:unsupported_effect_kind, :llm}} =
             capability.(Effect.Intent.new(:llm, %{}), Effect.Journal.new!(), context)

    assert {:error, {:missing_operation_handler, "wrong"}} =
             invoke(source, %{task: "valid"}, context, "wrong")

    assert {:error, {:invalid_subagent_task, nil}} = invoke(source, %{}, context)

    assert {:error, {:subagent_failed, "delegate", :child_failed}} =
             invoke(source, %{task: "valid", context: :invalid}, context)
  end

  defp invoke(source, arguments, context, name \\ nil) do
    {:ok, capability} = Source.capability(source)
    operation_name = name || source.name
    intent = Effect.Intent.new(:operation, %{name: operation_name, arguments: arguments})
    capability.(intent, Effect.Journal.new!(), context)
  end
end
