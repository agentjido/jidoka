defmodule Jidoka.SessionSequenceTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Schema
  alias Jidoka.Session
  alias Jidoka.Session.Sequence
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

      cond do
        message_with_content?(messages, "Store Atlas") and count_results(journal, :llm) == 0 ->
          {:ok,
           %{
             type: :operation,
             name: "lookup_project",
             arguments: %{"id" => "project-1"}
           }}

        message_with_content?(messages, "Store Atlas") ->
          {:ok, %{type: :final, content: "Stored Atlas"}}

        message_with_content?(messages, "Recall Atlas") ->
          assert message_with_content?(messages, "Stored Atlas")
          assert tool_observation?(messages, "lookup_project")
          {:ok, %{type: :final, content: "Atlas"}}

        message_with_content?(messages, "Confirm Atlas") ->
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

  test "rejects empty, duplicate, and caller-managed continuation input" do
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
              status: :error,
              terminal: %Sequence.Terminal{
                index: 2,
                request_id: "state-2",
                reason: {:sequence_continuation_state_forbidden, 2, "state-2"}
              }
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
end
