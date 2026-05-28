defmodule JidokaTest.SubagentUnitTest do
  use JidokaTest.Support.Case, async: false

  alias Jidoka.Subagent
  alias Jidoka.Subagent.{Context, Metadata}
  alias Jidoka.Subagent.Runtime.{Calls, Result}
  alias JidokaTest.{OrchestratorAgent, ResearchSpecialist, ReviewSpecialist}

  defmodule MissingRuntimeModule do
    def name, do: "missing_runtime"
    def start_link(_opts), do: {:error, :not_used}
    def chat(_pid, _message, _opts), do: {:ok, "not used"}
  end

  test "normalizes subagent definitions and validates option errors" do
    assert {:ok, %Subagent{} = subagent} =
             Subagent.new(ResearchSpecialist,
               as: "research_specialist",
               description: "  Ask the specialist.  ",
               target: {:peer, " research-peer "},
               timeout: 25,
               forward_context: %{"mode" => "only", "keys" => ["tenant", :notify_pid]},
               result: "structured"
             )

    assert subagent.name == "research_specialist"
    assert subagent.description == "Ask the specialist."
    assert subagent.target == {:peer, "research-peer"}
    assert subagent.timeout == 25
    assert subagent.forward_context == {:only, ["tenant", :notify_pid]}
    assert subagent.result == :structured

    assert {:error, reason} = Subagent.new(ResearchSpecialist, as: "Bad Name")
    assert reason =~ "subagent tool names"

    assert {:error, reason} = Subagent.validate_agent_module(MissingRuntimeModule)
    assert reason =~ "missing runtime_module/0"

    assert {:error, reason} = Subagent.validate_agent_module(JidokaTest.MissingChildAgent)
    assert reason =~ "could not be loaded"

    assert {:error, reason} = Subagent.normalize_target({:peer, " "})
    assert reason =~ "peer ids must not be empty"

    assert {:error, reason} = Subagent.normalize_timeout(0)
    assert reason =~ "positive integer"

    assert {:error, reason} = Subagent.normalize_result(:map)
    assert reason =~ "subagent result must be :text or :structured"
  end

  test "normalizes available subagent registries and lookup errors" do
    assert {:ok, registry} = Subagent.normalize_available_subagents([ResearchSpecialist, ReviewSpecialist])
    assert registry["research_agent"] == ResearchSpecialist
    assert registry["review_agent"] == ReviewSpecialist

    assert {:error, reason} = Subagent.normalize_available_subagents([ResearchSpecialist, ResearchSpecialist])
    assert reason =~ "unique"

    assert {:error, reason} = Subagent.normalize_available_subagents(%{"wrong_name" => ResearchSpecialist})
    assert reason =~ "must match published agent name"

    assert {:error, reason} = Subagent.resolve_subagent_name("unknown", registry)
    assert reason == ~s(unknown subagent "unknown")

    assert {:error, reason} = Subagent.resolve_subagent_name(:bad, registry)
    assert reason =~ "subagent name must be a string"
  end

  test "normalizes forward context policies with string and atom keys" do
    assert Subagent.normalize_forward_context("public") == {:ok, :public}
    assert Subagent.normalize_forward_context(%{"mode" => "none"}) == {:ok, :none}
    assert Subagent.normalize_forward_context({:except, ["secret"]}) == {:ok, {:except, ["secret"]}}

    assert {:error, reason} = Subagent.normalize_forward_context(%{"mode" => "only"})
    assert reason =~ "keys must be a list"

    assert {:error, reason} = Subagent.normalize_forward_context(%{"mode" => "private"})
    assert reason =~ "mode must be public, none, only, or except"

    assert {:error, reason} = Subagent.normalize_forward_context({:only, [""]})
    assert reason =~ "keys must not be empty"
  end

  test "child context applies forwarding policies and hides internal keys" do
    context = %{
      :tenant => "acme",
      "notify_pid" => self(),
      :secret => "drop",
      :__jidoka_hooks__ => %{before_turn: [:internal]},
      Jidoka.Memory.context_key() => %{prompt: "internal"},
      Context.request_id_key() => "req-hidden",
      Context.server_key() => self(),
      Context.depth_key() => "bad-depth"
    }

    only = Context.child_context(context, {:only, ["tenant", :notify_pid]})
    assert only.tenant == "acme"
    assert only["notify_pid"] == self()
    assert only[Context.depth_key()] == 1
    refute Map.has_key?(only, :secret)
    refute Map.has_key?(only, :__jidoka_hooks__)

    none = Context.child_context(context, :none)
    assert none == %{Context.depth_key() => 1}

    except = Context.child_context(context, {:except, [:secret, "notify_pid"]})
    assert except.tenant == "acme"
    refute Map.has_key?(except, :secret)
    refute Map.has_key?(except, "notify_pid")

    assert Context.context_keys(%{:tenant => "a", "tenant" => "b", 1 => "number"}) == ["1", "tenant"]
    assert Context.peer_ref_preview({:context, :peer_id}, %{"peer_id" => "peer-1"}) == "peer-1"
    assert Context.peer_ref_preview({:context, :peer_id}, %{}) == inspect({:context, :peer_id})
  end

  test "records, looks up, drains, and ignores invalid subagent metadata" do
    request_id = "req-subagent-metadata-#{System.unique_integer([:positive])}"
    context = %{Context.server_key() => self(), Context.request_id_key() => request_id}

    Calls.record_metadata(context, %{sequence: 2, name: "second"})
    Calls.record_metadata(context, %{sequence: 1, name: "first"})
    Calls.record_metadata(%{}, %{sequence: 3, name: "ignored"})

    assert [
             %{sequence: 1, name: "first"},
             %{sequence: 2, name: "second"}
           ] = Calls.request_calls(self(), request_id)

    assert [%{sequence: 2}, %{sequence: 1}] = Metadata.lookup(self(), request_id)
    assert [%{sequence: 2}, %{sequence: 1}] = Calls.drain_request_meta(self(), request_id)
    assert Calls.request_calls(self(), request_id) == []

    assert Metadata.lookup(:not_a_pid, request_id) == []
    assert Metadata.drain(self(), :not_a_request_id) == []
    assert Calls.request_calls(self(), :not_a_request_id) == []
    assert Calls.latest_request_calls("missing-subagent-server") == []
  end

  test "persists drained subagent metadata onto request state" do
    request_id = "req-subagent-after-cmd"
    runtime = OrchestratorAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    state =
      put_in(agent.state, [:requests, request_id], %{
        meta: %{jidoka_subagents: %{calls: [%{sequence: 1, name: "existing"}]}}
      })

    agent = %{agent | state: state}

    assert {:ok, _agent, {:ai_react_start, params}} =
             Subagent.on_before_cmd(agent, {:ai_react_start, %{request_id: request_id, tool_context: %{}}})

    Calls.record_metadata(params.tool_context, %{sequence: 2, name: "pending"})

    assert {:ok, agent, []} =
             Subagent.on_after_cmd(agent, {:ai_react_done, %{"event" => %{"request_id" => request_id}}}, [])

    assert %{calls: [%{name: "existing"}, %{name: "pending"}]} = Subagent.get_request_meta(agent, request_id)
  end

  test "renders structured visible results and normalized subagent errors" do
    metadata = %{
      name: "research_agent",
      agent: ResearchSpecialist,
      mode: :ephemeral,
      target: :ephemeral,
      child_id: "child-1",
      child_request_id: "child-req-1",
      duration_ms: 12,
      outcome: {:error, :boom},
      task_preview: "Investigate",
      result_preview: nil,
      context_keys: ["tenant"]
    }

    assert %{
             result: "answer",
             subagent: %{
               name: "research_agent",
               outcome: {:error, ":boom"},
               context_keys: ["tenant"]
             }
           } = Result.visible_result(%{result: :structured}, "answer", metadata)

    assert Result.visible_result(%{result: :text}, "answer", metadata) == %{result: "answer"}

    interrupt_metadata = %{metadata | outcome: {:interrupt, Jidoka.Interrupt.new(%{message: "Stop"})}}

    assert %{subagent: %{outcome: :interrupt}} =
             Result.visible_result(%{result: :structured}, "answer", interrupt_metadata)

    assert %Jidoka.Error.ValidationError{} =
             Result.normalize_error(
               %{name: "research_agent", target: :ephemeral},
               {:invalid_task, :expected_non_empty_string},
               %{},
               %{}
             )
  end
end
