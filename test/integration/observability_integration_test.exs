defmodule Jidoka.ObservabilityIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Eval
  alias Jidoka.Harness
  alias Jidoka.Harness.Session
  alias Jidoka.Trace
  alias Jidoka.Trace.Policy
  alias Jidoka.Trace.Sink.InMemory
  alias Jidoka.Turn

  test "session replay can be inspected, traced, and used as eval evidence" do
    spec =
      Agent.Spec.new!(
        id: "observability_agent",
        instructions: "Answer with observability evidence.",
        model: %{provider: :test, id: "model"}
      )

    llm = fn _intent, _journal, _ctx ->
      {:ok, %{type: :final, content: "Observability evidence captured."}}
    end

    assert {:ok, %Session{} = session} =
             Harness.start_session(spec, session_id: "sess_observability")

    assert {:ok, %Session{} = session, %Turn.Result{} = result} =
             Harness.run_session(session, "Capture observability evidence", llm: llm)

    assert {:ok, replay} = Harness.replay(session)

    assert %{kind: :session, replay: %{kind: :replay, timeline: timeline}} =
             Jidoka.inspect(session)

    assert Enum.map(timeline, & &1.event) == Enum.map(replay.timeline, & &1.event)

    {:ok, sink} = InMemory.start_link()

    assert :ok =
             Trace.record(result.events, {InMemory, pid: sink}, policy: Policy.new!(redact_keys: [], omit_keys: []))

    assert Enum.any?(InMemory.list(sink), &(&1.event == :turn_finished))

    assert {:ok, %Eval.Run{status: :passed, observations: %{event_count: event_count}}} =
             Eval.run_case(
               [
                 id: "eval_observability",
                 agent: spec,
                 input: "Capture observability evidence",
                 assertions: %{contains: "evidence"}
               ],
               llm: llm
             )

    assert event_count > 0
  end
end
