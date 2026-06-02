defmodule Jidoka.DebugTest do
  use ExUnit.Case, async: true

  alias Jidoka.Debug
  alias Jidoka.Debug.{ReplayDiagnostics, RequestSummary}
  alias Jidoka.Effect
  alias Jidoka.Harness
  alias Jidoka.Harness.Session
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  defmodule LookupAction do
    use Jidoka.Action,
      name: "debug_lookup",
      description: "Returns deterministic debug data.",
      schema: Zoi.object(%{id: Zoi.string()})

    @impl true
    def run(params, _context) do
      {:ok, %{id: Map.get(params, :id), status: "active"}}
    end
  end

  defmodule Agent do
    use Jidoka.Agent

    agent :debug_agent do
      model %{provider: :test, id: "debug-model"}
      instructions "Use debug_lookup before answering."
    end

    tools do
      action LookupAction
    end
  end

  test "request summaries explain completed turns" do
    assert {:ok, %Turn.Result{} = result} =
             Agent.run_turn("Check D-100.", llm: &tool_loop_llm/2)

    assert %{
             debug: %{
               request_id: request_id,
               prompt: %{
                 messages: messages,
                 operation_names: ["debug_lookup"]
               }
             }
           } = result.metadata

    assert Enum.map(messages, & &1.role) == [:system, :user, :tool]

    assert {:ok,
            %RequestSummary{
              request_id: ^request_id,
              agent_id: "debug_agent",
              status: :finished,
              model: "test:debug-model",
              input: "Check D-100.",
              content: "D-100 is active.",
              operation_names: ["debug_lookup"],
              operation_results: [%{operation: "debug_lookup"}],
              replay_diagnostics: %ReplayDiagnostics{status: :complete}
            } = summary} = Debug.request(result)

    assert Enum.any?(summary.timeline, &(&1.event == :turn_finished))
    assert summary.prompt.message_count == 3
    assert summary.usage.llm_calls == 2
  end

  test "session request summaries include session id and replay diagnostics" do
    assert {:ok, %Session{} = session} =
             Harness.start_session(Agent.spec(), session_id: "sess_debug")

    assert {:ok, %Session{} = session, %Turn.Result{} = result} =
             Harness.run_session(session, "Check D-100.",
               llm: &tool_loop_llm/2,
               operations: Jidoka.Runtime.JidoActions.operations([LookupAction])
             )

    assert {:ok,
            %RequestSummary{
              session_id: "sess_debug",
              request_id: request_id,
              replay_diagnostics: %ReplayDiagnostics{status: :complete}
            }} = Debug.latest(session)

    assert request_id == result.metadata.debug.request_id

    assert {:ok, %ReplayDiagnostics{status: :complete, intent_count: 3, result_count: 3}} =
             Harness.Replay.diagnose(session)
  end

  test "snapshot diagnostics flag incomplete pending effects" do
    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             Agent.run_turn("Pause after prompt.", llm: &tool_loop_llm/2, checkpoint: :after_prompt)

    assert {:ok,
            %RequestSummary{
              status: :running,
              replay_diagnostics: %ReplayDiagnostics{
                status: :incomplete,
                missing_effect_results: [_missing],
                warnings: warnings
              }
            }} = Debug.request(snapshot)

    assert "Some effect intents do not have recorded results." in warnings
  end

  test "Kino debug_request renders without requiring Kino" do
    assert {:ok, result} = Agent.run_turn("Check D-100.", llm: &tool_loop_llm/2)

    assert {:ok, %RequestSummary{operation_names: ["debug_lookup"]}} =
             Jidoka.Kino.debug_request(result)
  end

  defp tool_loop_llm(_intent, %Effect.Journal{} = journal) do
    llm_calls =
      journal.results
      |> Map.values()
      |> Enum.count(&(&1.kind == :llm))

    case llm_calls do
      0 ->
        {:ok,
         %{
           type: :operation,
           name: "debug_lookup",
           arguments: %{"id" => "D-100"},
           metadata: %{usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
         }}

      1 ->
        {:ok,
         %{
           type: :final,
           content: "D-100 is active.",
           metadata: %{usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
         }}
    end
  end
end
