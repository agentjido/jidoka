defmodule Jidoka.DebugTest do
  use ExUnit.Case, async: true

  alias Jidoka.Debug
  alias Jidoka.Debug.{ReplayDiagnostics, RequestSummary}
  alias Jidoka.Effect
  alias Jidoka.Event
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
             Agent.run_turn("Check D-100.", llm: &tool_loop_llm/3)

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
               llm: &tool_loop_llm/3,
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
             Agent.run_turn("Pause after prompt.", llm: &tool_loop_llm/3, checkpoint: :after_prompt)

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

  test "request summaries handle common result and error tuples" do
    assert {:ok, %Turn.Result{} = result} =
             Agent.run_turn("Check D-100.", llm: &tool_loop_llm/3)

    assert {:ok, %RequestSummary{status: :finished, session_id: nil}} =
             Debug.request({:ok, result})

    assert {:ok, %Session{} = session} =
             Harness.start_session(Agent.spec(), session_id: "sess_debug_tuple")

    assert {:ok, %RequestSummary{status: :finished, session_id: "sess_debug_tuple"}} =
             Debug.request({:ok, session, result})

    assert {:error, :boom} = Debug.request({:error, :boom})

    assert {:error, {:unsupported_debug_request_target, :not_debuggable}} =
             Debug.request(:not_debuggable)
  end

  test "request summaries handle hibernate tuples and replay projections" do
    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             Agent.run_turn("Pause after prompt.", llm: &tool_loop_llm/3, checkpoint: :after_prompt)

    assert {:ok, %Session{} = session} =
             Harness.start_session(Agent.spec(), session_id: "sess_snapshot_tuple")

    session =
      session
      |> Session.put_request(snapshot.turn_state.request)
      |> Session.put_snapshot(snapshot)

    assert {:ok,
            %RequestSummary{
              status: :running,
              session_id: nil,
              replay_diagnostics: %ReplayDiagnostics{status: :incomplete}
            }} = Debug.request({:hibernate, snapshot})

    assert {:ok,
            %RequestSummary{
              status: :running,
              session_id: "sess_snapshot_tuple",
              replay_diagnostics: %ReplayDiagnostics{status: :incomplete}
            }} = Debug.request({:hibernate, session, snapshot})

    assert {:ok, replay} = Harness.replay(session)

    assert {:ok,
            %RequestSummary{
              session_id: "sess_snapshot_tuple",
              status: :hibernated,
              replay_diagnostics: %ReplayDiagnostics{status: :incomplete}
            }} = Debug.request(replay)
  end

  test "session request summaries fall back to stored request data" do
    assert {:ok, %Session{} = session} =
             Harness.start_session(Agent.spec(), session_id: "sess_request_only")

    request =
      Turn.Request.new!(
        input: "Queued question.",
        request_id: "turn_request_only",
        context: %{"region" => "us", tenant_id: "acme"}
      )

    session = Session.put_request(session, request)

    assert {:ok,
            %RequestSummary{
              request_id: "turn_request_only",
              session_id: "sess_request_only",
              status: :running,
              input: "Queued question.",
              context_keys: ["region", "tenant_id"],
              replay_diagnostics: %ReplayDiagnostics{status: :complete}
            }} = Debug.request(session, request_id: "turn_request_only")
  end

  test "diagnostics flag failed effect results and failed timeline events" do
    intent =
      Effect.Intent.new(
        :operation,
        %{name: "debug_lookup", arguments: %{"id" => "D-500"}, request_id: "turn_failed"},
        idempotency: :unsafe_once
      )

    journal =
      Effect.Journal.new!()
      |> Effect.Journal.put_intent(intent)
      |> Effect.Journal.put_result(Effect.Result.error(intent, %{reason: "lookup failed"}))

    assert {:ok,
            %ReplayDiagnostics{
              status: :failed,
              intent_count: 1,
              result_count: 1,
              failed_effect_results: [%{intent_id: intent_id}],
              unsafe_effects: [%{idempotency: :unsafe_once}],
              warnings: journal_warnings
            }} = Debug.diagnose(journal)

    assert intent_id == intent.id
    assert "Some effect results failed." in journal_warnings
    assert "Some unsafe_once effects are not replay-safe." in journal_warnings

    failed_event =
      Event.build(:turn_failed, [],
        agent_id: "debug_agent",
        request_id: "turn_failed",
        error: %{reason: "lookup failed"}
      )

    replay =
      Harness.Replay.new!(
        agent_id: "debug_agent",
        status: :error,
        timeline: [Jidoka.project(failed_event)],
        journal: Jidoka.project(journal)
      )

    assert {:ok,
            %ReplayDiagnostics{
              status: :failed,
              failed_events: [%{event: :turn_failed}],
              warnings: replay_warnings
            }} = Debug.diagnose(replay)

    assert "Timeline contains failed events." in replay_warnings

    assert {:error, {:unsupported_replay_diagnostics_target, :not_replayable}} =
             Debug.diagnose(:not_replayable)
  end

  test "debug data contracts validate and normalize attrs" do
    assert ReplayDiagnostics.statuses() == [:complete, :waiting, :failed, :incomplete]

    assert {:ok, %ReplayDiagnostics{status: :waiting, warnings: ["Human review is still pending."]}} =
             ReplayDiagnostics.new(
               status: :waiting,
               warnings: ["Human review is still pending."]
             )

    assert {:ok,
            %RequestSummary{
              request_id: "turn_contract",
              context_keys: ["tenant"],
              replay_diagnostics: %ReplayDiagnostics{status: :complete}
            }} =
             RequestSummary.new(%{
               "request_id" => "turn_contract",
               "context_keys" => ["tenant"],
               "replay_diagnostics" => %{status: :complete}
             })

    assert {:error, _reason} = ReplayDiagnostics.new(status: :unknown)

    assert_raise ArgumentError, ~r/invalid debug request summary/, fn ->
      RequestSummary.new!(request_id: "")
    end
  end

  test "Kino debug_request renders without requiring Kino" do
    assert {:ok, result} = Agent.run_turn("Check D-100.", llm: &tool_loop_llm/3)

    assert {:ok, %RequestSummary{operation_names: ["debug_lookup"]}} =
             Jidoka.Kino.debug_request(result)
  end

  defp tool_loop_llm(_intent, %Effect.Journal{} = journal, _ctx) do
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
