defmodule Jidoka.SessionSequenceTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Cancellation
  alias Jidoka.Effect
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Schema
  alias Jidoka.Session
  alias Jidoka.Session.Sequence
  alias Jidoka.Session.Sequence.Request, as: SequenceRequest
  alias Jidoka.Session.Store.InMemory
  alias Jidoka.Snapshot
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  test "runs three turns with semantic continuity and turn-scoped operations" do
    test_pid = self()

    operations =
      LocalOperations.operations(%{
        "lookup_project" => fn arguments, _context ->
          send(test_pid, {:operation_called, arguments})
          %{"project" => "Atlas"}
        end
      })

    llm = fn %Effect.Intent{payload: payload}, %Effect.Journal{} = journal, _context ->
      messages = payload |> Schema.get_key(:prompt) |> Schema.get_key(:messages, [])

      current_user_message =
        messages
        |> Enum.filter(&(Schema.get_key(&1, :role) in [:user, "user"]))
        |> List.last()
        |> Schema.get_key(:content)

      cond do
        current_user_message == "Store Atlas" and count_results(journal, :llm) == 0 ->
          {:ok,
           %{
             type: :operation,
             name: "lookup_project",
             arguments: %{"id" => "project-1"}
           }}

        current_user_message == "Store Atlas" ->
          {:ok, %{type: :final, content: "Stored Atlas"}}

        current_user_message == "Recall Atlas" ->
          assert message_with_content?(messages, "Stored Atlas")
          assert tool_observation?(messages, "lookup_project")
          {:ok, %{type: :final, content: "Atlas"}}

        current_user_message == "Confirm Atlas" ->
          assert message_with_content?(messages, "Stored Atlas")
          assert message_with_content?(messages, "Atlas")
          {:ok, %{type: :final, content: "Confirmed Atlas"}}
      end
    end

    assert {:ok, session} = Session.start(spec_with_operation(), "sequence-continuity")

    requests = [
      request("Store Atlas", "sequence-1"),
      request("Recall Atlas", "sequence-2"),
      request("Confirm Atlas", "sequence-3")
    ]

    assert {:ok, %Sequence.Result{status: :completed, terminal: nil} = sequence} =
             Session.run_sequence(session, requests, llm: llm, operations: operations)

    assert_receive {:operation_called, %{"id" => "project-1"}}
    refute_receive {:operation_called, _arguments}

    assert Enum.map(sequence.steps, & &1.result.content) == [
             "Stored Atlas",
             "Atlas",
             "Confirmed Atlas"
           ]

    assert Enum.map(sequence.steps, fn step ->
             Enum.map(step.operation_results, & &1.operation)
           end) == [["lookup_project"], [], []]

    assert length(List.last(sequence.steps).result.agent_state.operation_results) == 1
    assert Enum.map(sequence.session.requests, & &1.request_id) == ~w(sequence-1 sequence-2 sequence-3)
    assert sequence.session.conversation.agent_state == List.last(sequence.steps).result.agent_state
    assert sequence.session.conversation.turn_count == 3
  end

  test "sequence and repeated session calls create the same transcript" do
    llm = fn %Effect.Intent{payload: payload}, _journal, _context ->
      messages = payload |> Schema.get_key(:prompt) |> Schema.get_key(:messages, [])

      current =
        messages
        |> Enum.filter(&(Schema.get_key(&1, :role) in [:user, "user"]))
        |> List.last()
        |> Schema.get_key(:content)

      {:ok, %{type: :final, content: "answer:#{current}"}}
    end

    requests = [request("First", "compare-1"), request("Second", "compare-2")]
    assert {:ok, sequence_session} = Session.start(spec(), "sequence-compare")

    assert {:ok, %Sequence.Result{status: :completed} = sequence} =
             Session.run_sequence(sequence_session, requests, llm: llm)

    assert {:ok, repeated_session} = Session.start(spec(), "repeated-compare")
    assert {:ok, after_first, first_result} = Session.run(repeated_session, hd(requests), llm: llm)
    assert {:ok, after_second, second_result} = Session.run(after_first, List.last(requests), llm: llm)

    assert sequence.session.conversation == after_second.conversation
    assert Enum.map(sequence.steps, & &1.result.content) == [first_result.content, second_result.content]
    assert Enum.map(sequence.steps, & &1.operation_results) == [[], []]
  end

  test "keeps fresh sessions isolated" do
    llm = fn %Effect.Intent{payload: payload}, _journal, _context ->
      messages = payload |> Schema.get_key(:prompt) |> Schema.get_key(:messages, [])

      if message_with_content?(messages, "First private answer") do
        flunk("a fresh session received state from another sequence")
      end

      {:ok, %{type: :final, content: "Second isolated answer"}}
    end

    assert {:ok, first} = Session.start(spec(), "sequence-isolation-a")

    assert {:ok, %Sequence.Result{status: :completed}} =
             Session.run_sequence(first, [request("First", "isolation-a")], llm: final_llm("First private answer"))

    assert {:ok, second} = Session.start(spec(), "sequence-isolation-b")

    assert {:ok, %Sequence.Result{status: :completed, steps: [step]}} =
             Session.run_sequence(second, [request("Second", "isolation-b")], llm: llm)

    assert step.result.content == "Second isolated answer"
  end

  test "reports invalid request identity and does not start later requests" do
    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)

    llm = fn _intent, _journal, _context ->
      call = Elixir.Agent.get_and_update(calls, &{&1, &1 + 1})
      {:ok, %{type: :final, content: "answer-#{call}"}}
    end

    assert {:ok, session} = Session.start(spec(), "sequence-invalid")

    requests = [
      request("First", "valid-1"),
      %{input: "", request_id: "invalid-2"},
      request("Never", "never-3")
    ]

    assert {:ok,
            %Sequence.Result{
              status: :error,
              steps: [%Sequence.Step{request: %{request_id: "valid-1"}}],
              terminal: %Sequence.Terminal{
                kind: :error,
                index: 2,
                request_id: "invalid-2"
              }
            }} = Session.run_sequence(session, requests, llm: llm)

    assert Elixir.Agent.get(calls, & &1) == 1
  end

  test "rejects empty and duplicate input and ignores caller-managed continuation state" do
    assert {:ok, session} = Session.start(spec(), "sequence-validation")
    assert {:error, :empty_session_sequence} = Session.run_sequence(session, [])

    assert {:ok,
            %Sequence.Result{
              status: :error,
              terminal: %Sequence.Terminal{
                index: 2,
                reason: {:duplicate_sequence_request_id, 2, "duplicate"}
              }
            }} =
             Session.run_sequence(
               session,
               [request("First", "duplicate"), request("Second", "duplicate")],
               llm: final_llm("done")
             )

    assert {:ok, other_session} = Session.start(spec(), "sequence-state-validation")

    injected_state = Agent.State.new!(metadata: %{caller_owned: true})

    assert {:ok,
            %Sequence.Result{
              status: :completed,
              terminal: nil,
              steps: [_, %Sequence.Step{result: second_result}]
            }} =
             Session.run_sequence(
               other_session,
               [
                 request("First", "state-1"),
                 Turn.Request.new!(
                   input: "Second",
                   request_id: "state-2",
                   agent_state: injected_state
                 )
               ],
               llm: final_llm("done")
             )

    refute second_result.agent_state.metadata[:caller_owned]
  end

  test "stops on a model error and returns the completed prefix" do
    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)

    llm = fn _intent, _journal, _context ->
      case Elixir.Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:ok, %{type: :final, content: "first complete"}}
        1 -> {:error, :provider_offline}
        _call -> flunk("a request ran after the terminal error")
      end
    end

    assert {:ok, session} = Session.start(spec(), "sequence-error")

    assert {:ok,
            %Sequence.Result{
              status: :error,
              steps: [%Sequence.Step{result: %{content: "first complete"}}],
              terminal: %Sequence.Terminal{index: 2, request_id: "error-2"}
            }} =
             Session.run_sequence(
               session,
               [request("First", "error-1"), request("Fail", "error-2"), request("Never", "error-3")],
               llm: llm
             )

    assert Elixir.Agent.get(calls, & &1) == 2
  end

  test "stops on hibernation and cancellation" do
    assert {:ok, hibernate_session} = Session.start(spec(), "sequence-hibernate")

    assert {:ok,
            %Sequence.Result{
              status: :hibernated,
              steps: [],
              session: %{status: :hibernated},
              terminal: %Sequence.Terminal{
                kind: :hibernated,
                index: 1,
                snapshot: %Snapshot{}
              }
            }} =
             Session.run_sequence(
               hibernate_session,
               [request("Pause", "hibernate-1"), request("Never", "hibernate-2")],
               checkpoint: :after_prompt,
               llm: final_llm("never called")
             )

    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)

    cancelling_llm = fn _intent, _journal, _context ->
      case Elixir.Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:ok, %{type: :final, content: "first complete"}}
        1 -> {:error, :cancelled}
        _call -> flunk("a request ran after cancellation")
      end
    end

    assert {:ok, cancel_session} = Session.start(spec(), "sequence-cancel")

    assert {:ok,
            %Sequence.Result{
              status: :cancelled,
              steps: [%Sequence.Step{}],
              terminal: %Sequence.Terminal{kind: :cancelled, index: 2}
            }} =
             Session.run_sequence(
               cancel_session,
               [request("First", "cancel-1"), request("Cancel", "cancel-2"), request("Never", "cancel-3")],
               llm: cancelling_llm
             )

    assert Elixir.Agent.get(calls, & &1) == 2
  end

  test "uses sequential store claims and releases every lease" do
    {:ok, store_pid} = InMemory.start_link()
    store = {InMemory, pid: store_pid}

    assert {:ok, session} =
             Session.start(spec(), "sequence-store", store: store)

    assert {:ok, %Sequence.Result{status: :completed, session: finished}} =
             Session.run_sequence(
               session,
               [request("First", "store-1"), request("Second", "store-2")],
               store: store,
               owner_id: "sequence-worker",
               clock: fn -> 1_000 end,
               llm: final_llm("stored")
             )

    assert finished.lease == nil
    assert finished.revision >= 4
    assert Enum.map(finished.requests, & &1.request_id) == ~w(store-1 store-2)
    assert {:ok, ^finished} = Session.get(store, "sequence-store")
  end

  test "cancels an active asynchronous sequence and returns the completed prefix" do
    parent = self()
    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)

    llm = fn _intent, _journal, context ->
      case Elixir.Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 ->
          {:ok, %{type: :final, content: "first complete"}}

        1 ->
          send(parent, {:sequence_capability_started, self()})
          :ok = wait_for_cancellation(context, 1_000)
          send(parent, {:sequence_capability_cleaned_up, self()})
          {:error, :cancelled}

        _call ->
          flunk("a later sequence turn started after cancellation")
      end
    end

    assert {:ok, session} = Session.start(spec(), "sequence-async-cancel")

    assert {:ok, request_handle} =
             Session.run_sequence_async(
               session,
               [request("First", "async-1"), request("Block", "async-2"), request("Never", "async-3")],
               llm: llm,
               sequence_request_id: "sequence-request-1"
             )

    refute Map.has_key?(Map.from_struct(request_handle), :task)
    assert_receive {:sequence_capability_started, capability_pid}, 1_000

    assert {:ok,
            %Cancellation{
              request_id: "sequence-request-1",
              forced?: false
            } = cancellation} = Jidoka.cancel(request_handle, grace_ms: 500)

    assert {:cancelled, ^cancellation,
            %Sequence.Result{
              status: :cancelled,
              steps: [%Sequence.Step{result: %{content: "first complete"}}],
              terminal: %Sequence.Terminal{
                index: 2,
                request_id: "async-2",
                cancellation: ^cancellation,
                reason: ^cancellation
              },
              session: %{status: :cancelled, error: ^cancellation}
            } = sequence} = Jidoka.await(request_handle, timeout: 100)

    assert sequence |> Jidoka.project() |> Jason.encode!() |> is_binary()

    assert_receive {:sequence_capability_cleaned_up, ^capability_pid}, 1_000
    assert Elixir.Agent.get(calls, & &1) == 2
    assert {:error, :request_already_finished} = Jidoka.cancel(request_handle)
  end

  test "forces bounded asynchronous sequence cancellation and keeps prior steps" do
    parent = self()
    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)

    llm = fn _intent, _journal, _context ->
      case Elixir.Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 ->
          {:ok, %{type: :final, content: "first complete"}}

        1 ->
          send(parent, {:noncooperative_sequence_started, self()})
          Process.sleep(5_000)
          {:ok, %{type: :final, content: "too late"}}

        _call ->
          flunk("a later sequence turn started after forced cancellation")
      end
    end

    assert {:ok, session} = Session.start(spec(), "sequence-async-forced")

    assert {:ok, request_handle} =
             Session.run_sequence_async(
               session,
               [request("First", "forced-1"), request("Block", "forced-2"), request("Never", "forced-3")],
               llm: llm,
               sequence_request_id: "sequence-request-forced"
             )

    assert_receive {:noncooperative_sequence_started, capability_pid}, 1_000

    assert {:ok, %Cancellation{forced?: true} = cancellation} =
             Jidoka.cancel(request_handle, grace_ms: 5)

    assert {:cancelled, ^cancellation,
            %Sequence.Result{
              steps: [%Sequence.Step{result: %{content: "first complete"}}],
              terminal: %Sequence.Terminal{index: 2, request_id: "forced-2"}
            }} = Jidoka.await(request_handle, timeout: 100)

    refute Process.alive?(capability_pid)
    assert Elixir.Agent.get(calls, & &1) == 2
  end

  test "releases store leases for cooperative and forced sequence cancellation" do
    for mode <- [:cooperative, :forced] do
      parent = self()
      {:ok, store_pid} = InMemory.start_link()
      store = {InMemory, pid: store_pid}
      session_id = "sequence-store-cancel-#{mode}"

      assert {:ok, session} = Session.start(spec(), session_id, store: store)

      llm = fn _intent, _journal, context ->
        send(parent, {:stored_sequence_started, mode, self()})

        case mode do
          :cooperative ->
            :ok = wait_for_cancellation(context, 1_000)
            {:error, :cancelled}

          :forced ->
            Process.sleep(5_000)
            {:ok, %{type: :final, content: "too late"}}
        end
      end

      assert {:ok, request_handle} =
               Session.run_sequence_async(
                 session.session_id,
                 [request("Block", "stored-#{mode}-1"), request("Never", "stored-#{mode}-2")],
                 store: store,
                 llm: llm,
                 sequence_request_id: "stored-sequence-#{mode}"
               )

      assert_receive {:stored_sequence_started, ^mode, capability_pid}, 1_000
      grace_ms = if mode == :cooperative, do: 500, else: 5

      assert {:ok, %Cancellation{forced?: forced?} = cancellation} =
               Jidoka.cancel(request_handle, grace_ms: grace_ms)

      assert forced? == (mode == :forced)

      assert {:cancelled, ^cancellation, %Sequence.Result{session: cancelled_session}} =
               Jidoka.await(request_handle, timeout: 100)

      assert cancelled_session.status == :cancelled
      assert cancelled_session.lease == nil
      assert cancelled_session.error == cancellation

      assert {:ok, stored_session} = Session.get(store, session_id)
      assert stored_session.status == :cancelled
      assert stored_session.lease == nil
      assert stored_session.error == cancellation
      refute Process.alive?(capability_pid)
    end
  end

  test "a completed asynchronous sequence wins later cancellation" do
    assert {:ok, session} = Session.start(spec(), "sequence-async-complete")

    assert {:ok, request_handle} =
             Session.run_sequence_async(
               session,
               [request("Complete", "complete-1")],
               llm: final_llm("done"),
               sequence_request_id: "sequence-request-complete"
             )

    assert {:ok, %Sequence.Result{status: :completed}} =
             Jidoka.await(request_handle, timeout: 1_000)

    assert {:error, :request_already_finished} = Jidoka.cancel(request_handle)
    assert {:ok, %Sequence.Result{status: :completed}} = Jidoka.await(request_handle)
  end

  test "a sequence handle expires after its owner exits" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, session} = Session.start(spec(), "sequence-expired-owner")

        {:ok, request_handle} =
          Session.run_sequence_async(
            session,
            [request("Block", "expired-1")],
            llm: fn _intent, _journal, _context ->
              Process.sleep(5_000)
              {:ok, %{type: :final, content: "too late"}}
            end
          )

        send(parent, {:sequence_owner_handle, request_handle})
        Process.sleep(:infinity)
      end)

    assert_receive {:sequence_owner_handle, request_handle}, 1_000
    assert {:ok, controller} = SequenceRequest.controller(request_handle)
    monitor = Process.monitor(controller)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^controller, :normal}, 1_000

    assert {:error, :request_expired} = Jidoka.await(request_handle)
    assert {:error, :request_expired} = Jidoka.cancel(request_handle)
  end

  test "projects a sequence result as JSON-portable data" do
    assert {:ok, session} = Session.start(spec(), "sequence-projection")

    assert {:ok, %Sequence.Result{} = result} =
             Session.run_sequence(session, [request("Project", "project-1")], llm: final_llm("portable"))

    projection = Jidoka.project(result)
    assert projection.status == :completed
    assert [%{request: %{request_id: "project-1"}}] = projection.steps
    assert is_binary(Jason.encode!(projection))
  end

  defp spec do
    Agent.Spec.new!(
      id: "sequence_agent",
      instructions: "Answer with sequence state.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp spec_with_operation do
    Agent.Spec.new!(
      id: "sequence_operation_agent",
      instructions: "Use lookup_project when asked.",
      model: %{provider: :test, id: "model"},
      operations: [
        Operation.new!(
          name: "lookup_project",
          description: "Looks up one project.",
          idempotency: :idempotent
        )
      ]
    )
  end

  defp request(input, request_id) do
    Turn.Request.new!(input: input, request_id: request_id)
  end

  defp final_llm(content) do
    fn _intent, _journal, _context -> {:ok, %{type: :final, content: content}} end
  end

  defp message_with_content?(messages, expected) do
    Enum.any?(messages, fn message ->
      message
      |> Schema.get_key(:content, "")
      |> to_string()
      |> String.contains?(expected)
    end)
  end

  defp tool_observation?(messages, operation) do
    Enum.any?(messages, fn message ->
      Schema.get_key(message, :role) == :tool and
        Schema.get_key(message, :operation) == operation
    end)
  end

  defp wait_for_cancellation(_context, 0), do: {:error, :cancellation_not_received}

  defp wait_for_cancellation(context, attempts_left) do
    if Cancellation.requested?(context) do
      :ok
    else
      Process.sleep(1)
      wait_for_cancellation(context, attempts_left - 1)
    end
  end
end
