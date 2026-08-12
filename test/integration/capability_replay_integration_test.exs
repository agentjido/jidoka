defmodule Jidoka.CapabilityReplayIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Policy.Gate
  alias Jidoka.Replay.Capabilities, as: ReplayCapabilities
  alias Jidoka.Replay.Recorder
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Session
  alias Jidoka.Session.Sequence
  alias Jidoka.Turn

  test "records and replays a multi-turn tool loop through the normal sequence runtime" do
    {:ok, llm_calls} = Elixir.Agent.start_link(fn -> 0 end)
    test_pid = self()

    llm = fn _intent, _journal, _context ->
      case Elixir.Agent.get_and_update(llm_calls, &{&1, &1 + 1}) do
        0 -> {:ok, %{type: :operation, name: "lookup", arguments: %{"id" => "A-1"}}}
        1 -> {:ok, %{type: :final, content: "Stored Atlas"}}
        2 -> {:ok, %{type: :final, content: "Atlas"}}
      end
    end

    operations =
      LocalOperations.operations(%{
        "lookup" => fn arguments, _context ->
          send(test_pid, {:live_operation, arguments})
          {:ok, %{"project" => "Atlas"}}
        end
      })

    live = Capabilities.new!(llm: llm, operations: operations, policy: &Gate.default/2)
    {:ok, recorder} = Recorder.start_recording(compatibility: %{"agent" => "replay-agent-v1"})
    recorded = ReplayCapabilities.record(live, recorder)
    requests = [request("Store", "replay-1"), request("Recall", "replay-2")]

    assert {:ok, session} = Session.start(spec(), "capability-replay-session")

    assert {:ok, %Sequence.Result{status: :completed} = original} =
             Session.run_sequence(session, requests, capabilities: recorded, clock: fn -> 1_000 end)

    assert_receive {:live_operation, %{"id" => "A-1"}}
    assert Enum.map(original.steps, & &1.result.content) == ["Stored Atlas", "Atlas"]

    assert Enum.map(original.steps, &Enum.map(&1.operation_results, fn result -> result.operation end)) == [
             ["lookup"],
             []
           ]

    assert {:ok, fixture} = Recorder.fixture(recorder)
    classes = Enum.map(fixture.entries, & &1.class)
    assert "llm" in classes
    assert "operation" in classes
    assert "policy" in classes

    {:ok, player} = Recorder.start_replay(fixture, compatibility: %{"agent" => "replay-agent-v1"})
    replayed = ReplayCapabilities.replay(player)
    assert {:ok, replay_session} = Session.start(spec(), "different-replay-session")

    assert {:ok, %Sequence.Result{status: :completed} = replay} =
             Session.run_sequence(
               replay_session,
               [request("Store", "different-1"), request("Recall", "different-2")],
               capabilities: replayed,
               clock: fn -> 1_000 end
             )

    refute_receive {:live_operation, _arguments}
    assert Enum.map(replay.steps, & &1.result.content) == Enum.map(original.steps, & &1.result.content)

    assert Enum.map(replay.steps, &Enum.map(&1.operation_results, fn result -> result.output end)) ==
             Enum.map(original.steps, &Enum.map(&1.operation_results, fn result -> result.output end))

    assert :ok = Recorder.finish(player)
    assert Elixir.Agent.get(llm_calls, & &1) == 3
  end

  test "replays terminal cancellation, provider error, policy denial, and hibernation" do
    for {name, llm, expected_status} <- [
          {:cancelled, fn _intent, _journal, _context -> {:error, :cancelled} end, :cancelled},
          {:provider_error, fn _intent, _journal, _context -> {:error, :provider_offline} end, :error},
          {:timeout, fn _intent, _journal, _context -> {:error, {:capability_timeout, :llm, 5}} end, :error}
        ] do
      assert_replayed_terminal(name, llm, expected_status)
    end

    deny = fn _request, _context ->
      {:ok,
       Jidoka.Policy.Decision.new!(
         outcome: :deny,
         rule_id: "test.deny",
         reason: :blocked,
         evidence: %{"source" => "test"}
       )}
    end

    live = Capabilities.new!(llm: fn _, _, _ -> flunk("denied call reached model") end, policy: deny)
    {:ok, recorder} = Recorder.start_recording()
    assert {:ok, session} = Session.start(simple_spec(), "policy-replay")

    assert {:ok, %Sequence.Result{status: :error}} =
             Session.run_sequence(session, [request("Denied", "policy-1")],
               capabilities: ReplayCapabilities.record(live, recorder),
               clock: fn -> 10 end
             )

    {:ok, fixture} = Recorder.fixture(recorder)
    assert Enum.map(fixture.entries, & &1.class) == ["policy"]
    {:ok, player} = Recorder.start_replay(fixture)
    assert {:ok, replay_session} = Session.start(simple_spec(), "policy-replay")

    assert {:ok, %Sequence.Result{status: :error}} =
             Session.run_sequence(replay_session, [request("Denied", "policy-1")],
               capabilities: ReplayCapabilities.replay(player),
               clock: fn -> 10 end
             )

    assert :ok = Recorder.finish(player)

    {:ok, hibernate_recorder} = Recorder.start_recording()
    hibernate_live = Capabilities.new!(llm: fn _, _, _ -> flunk("hibernated call reached model") end)
    assert {:ok, hibernate_session} = Session.start(simple_spec(), "hibernate-replay")

    assert {:ok, %Sequence.Result{status: :hibernated}} =
             Session.run_sequence(hibernate_session, [request("Pause", "hibernate-1")],
               capabilities: ReplayCapabilities.record(hibernate_live, hibernate_recorder),
               checkpoint: :after_prompt
             )

    {:ok, empty_fixture} = Recorder.fixture(hibernate_recorder)
    assert empty_fixture.entries == []
    {:ok, hibernate_player} = Recorder.start_replay(empty_fixture)
    assert {:ok, replay_hibernate_session} = Session.start(simple_spec(), "hibernate-replay")

    assert {:ok, %Sequence.Result{status: :hibernated}} =
             Session.run_sequence(replay_hibernate_session, [request("Pause", "hibernate-1")],
               capabilities: ReplayCapabilities.replay(hibernate_player),
               checkpoint: :after_prompt
             )

    assert :ok = Recorder.finish(hibernate_player)
  end

  test "replays a recorded operation error without calling the live handler" do
    llm = fn _intent, _journal, _context ->
      {:ok, %{type: :operation, name: "lookup", arguments: %{"id" => "bad"}}}
    end

    operations = LocalOperations.operations(%{"lookup" => fn _, _ -> {:error, :tool_offline} end})
    live = Capabilities.new!(llm: llm, operations: operations)
    {:ok, recorder} = Recorder.start_recording()
    assert {:ok, session} = Session.start(spec(), "operation-error-replay")

    assert {:ok, %Sequence.Result{status: :error}} =
             Session.run_sequence(session, [request("Lookup", "operation-error-1")],
               capabilities: ReplayCapabilities.record(live, recorder)
             )

    {:ok, fixture} = Recorder.fixture(recorder)
    assert Enum.any?(fixture.entries, &(&1.class == "operation" and &1.outcome == "error"))
    {:ok, player} = Recorder.start_replay(fixture)
    assert {:ok, replay_session} = Session.start(spec(), "operation-error-replay")

    assert {:ok, %Sequence.Result{status: :error}} =
             Session.run_sequence(replay_session, [request("Lookup", "operation-error-1")],
               capabilities: ReplayCapabilities.replay(player)
             )

    assert :ok = Recorder.finish(player)
  end

  defp assert_replayed_terminal(name, llm, expected_status) do
    session_id = "terminal-replay-#{name}"
    request_id = "terminal-#{name}-1"
    live = Capabilities.new!(llm: llm)
    {:ok, recorder} = Recorder.start_recording()
    assert {:ok, session} = Session.start(simple_spec(), session_id)

    assert {:ok, %Sequence.Result{status: ^expected_status}} =
             Session.run_sequence(session, [request("Terminal", request_id)],
               capabilities: ReplayCapabilities.record(live, recorder),
               clock: fn -> 100 end
             )

    {:ok, fixture} = Recorder.fixture(recorder)
    {:ok, player} = Recorder.start_replay(fixture)
    assert {:ok, replay_session} = Session.start(simple_spec(), session_id)

    assert {:ok, %Sequence.Result{status: ^expected_status}} =
             Session.run_sequence(replay_session, [request("Terminal", request_id)],
               capabilities: ReplayCapabilities.replay(player),
               clock: fn -> 100 end
             )

    assert :ok = Recorder.finish(player)
  end

  defp spec do
    Agent.Spec.new!(
      id: "capability_replay_agent",
      instructions: "Use lookup, then answer.",
      model: %{provider: :test, id: "model"},
      operations: [Operation.new!(name: "lookup", description: "Lookup project", idempotency: :idempotent)]
    )
  end

  defp simple_spec do
    Agent.Spec.new!(
      id: "simple_replay_agent",
      instructions: "Answer.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp request(input, request_id), do: Turn.Request.new!(input: input, request_id: request_id)
end
