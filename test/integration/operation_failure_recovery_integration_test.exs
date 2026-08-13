defmodule Jidoka.OperationFailureRecoveryIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.CodingPack.Error, as: CodingError
  alias Jidoka.Effect
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Turn

  test "a stale edit becomes an observation before read, corrected edit, verify, and final" do
    {:ok, model_step} = Elixir.Agent.start_link(fn -> 0 end)
    parent = self()

    llm = fn _intent, _journal, _ctx ->
      step = Elixir.Agent.get_and_update(model_step, &{&1, &1 + 1})

      decision =
        case step do
          0 -> %{type: :operation, name: "coding.edit", arguments: %{expected: "stale"}}
          1 -> %{type: :operation, name: "coding.read", arguments: %{path: "lib/app.ex"}}
          2 -> %{type: :operation, name: "coding.edit", arguments: %{expected: "current"}}
          3 -> %{type: :operation, name: "coding.verify", arguments: %{target: "test"}}
          4 -> %{type: :final, content: "The corrected edit is verified."}
        end

      {:ok, decision}
    end

    operations =
      LocalOperations.operations(%{
        "coding.edit" => fn arguments, _ctx ->
          expected = arguments["expected"]
          send(parent, {:edit, expected})

          if expected == "stale" do
            {:error,
             CodingError.new(:coding_write_conflict, %{
               expected: "sha256:stale",
               actual: "sha256:current"
             })}
          else
            {:ok, %{"changed" => true, "sha256" => "sha256:fixed"}}
          end
        end,
        "coding.read" => fn arguments, _ctx ->
          path = arguments["path"]
          send(parent, {:read, path})
          {:ok, %{"path" => path, "sha256" => "sha256:current"}}
        end,
        "coding.verify" => fn arguments, _ctx ->
          send(parent, {:verify, arguments["target"]})
          {:ok, %{"status" => "passed"}}
        end
      })

    assert {:ok, %Turn.Result{content: "The corrected edit is verified."} = result} =
             Jidoka.turn(spec(), "Fix and verify the stale edit.", llm: llm, operations: operations)

    assert_receive {:edit, "stale"}
    assert_receive {:read, "lib/app.ex"}
    assert_receive {:edit, "current"}
    assert_receive {:verify, "test"}

    assert [failed_edit, read, corrected_edit, verify] = result.agent_state.operation_results
    assert failed_edit.operation == "coding.edit"
    assert failed_edit.output["ok"] == false
    assert failed_edit.output["error"]["code"] == "coding_write_conflict"
    assert failed_edit.metadata.operation_failure.kind == :recoverable
    assert read.operation == "coding.read"
    assert corrected_edit.operation == "coding.edit"
    assert verify.operation == "coding.verify"

    observed = Enum.filter(result.events, &(&1.event == :operation_observed))
    assert Enum.map(observed, & &1.operation) == ["coding.edit", "coding.read", "coding.edit", "coding.verify"]
    assert hd(observed).data == %{outcome: :failed, failure_kind: :recoverable, attempts: 1}
    assert Enum.all?(tl(observed), &(&1.data.outcome == :completed))
  end

  test "a recoverable failure does not hide its parallel batch siblings" do
    llm = fn _intent, journal, _ctx ->
      if operation_result_count(journal) == 0 do
        {:ok,
         %{
           type: :operations,
           operations: [
             %{name: "read_a", arguments: %{}},
             %{name: "stale_edit", arguments: %{}},
             %{name: "read_b", arguments: %{}}
           ]
         }}
      else
        {:ok, %{type: :final, content: "All batch results are visible."}}
      end
    end

    operations =
      LocalOperations.operations(%{
        "read_a" => fn _arguments, _ctx -> {:ok, %{value: "a"}} end,
        "stale_edit" => fn _arguments, _ctx ->
          {:error, CodingError.new(:coding_write_conflict, %{actual: "new"})}
        end,
        "read_b" => fn _arguments, _ctx -> {:ok, %{value: "b"}} end
      })

    assert {:ok, %Turn.Result{} = result} =
             Jidoka.turn(batch_spec(), "Run the batch.",
               llm: llm,
               operations: operations,
               max_parallel_operations: 3
             )

    assert Enum.map(result.agent_state.operation_results, & &1.operation) == [
             "read_a",
             "stale_edit",
             "read_b"
           ]

    assert [first, failed, third] = result.agent_state.operation_results
    assert first.output == %{value: "a"}
    assert failed.output["ok"] == false
    assert third.output == %{value: "b"}
  end

  test "a terminal batch failure keeps every sibling capability outcome visible" do
    request_id = "terminal-batch-siblings"

    llm = fn _intent, _journal, _ctx ->
      {:ok,
       %{
         type: :operations,
         operations: [
           %{name: "read_a", arguments: %{}},
           %{name: "stale_edit", arguments: %{}},
           %{name: "read_b", arguments: %{}}
         ]
       }}
    end

    operations =
      LocalOperations.operations(%{
        "read_a" => fn _arguments, _ctx -> {:ok, %{value: "a"}} end,
        "stale_edit" => fn _arguments, _ctx ->
          {:error, Jidoka.Effect.OperationFailure.runtime(:adapter_failed)}
        end,
        "read_b" => fn _arguments, _ctx -> {:ok, %{value: "b"}} end
      })

    request = Turn.Request.new!(input: "Run the terminal batch.", request_id: request_id)

    assert {:error, %Jidoka.Error.ExecutionError{}} =
             Jidoka.turn(batch_spec(), request,
               llm: llm,
               operations: operations,
               max_parallel_operations: 3,
               stream_to: self()
             )

    terminal_operations =
      request_id
      |> Jidoka.Stream.events(stream_event_timeout_ms: 25)
      |> Enum.filter(
        &(&1.effect_kind == :operation and
            &1.event in [:capability_call_completed, :capability_call_failed])
      )
      |> Enum.map(& &1.operation)
      |> Enum.sort()

    assert terminal_operations == ["read_a", "read_b", "stale_edit"]
  end

  defp operation_result_count(%Effect.Journal{results: results}) do
    Enum.count(results, fn {_id, result} -> result.kind == :operation end)
  end

  defp spec do
    Agent.Spec.new!(
      id: "operation_recovery_agent",
      instructions: "Recover from a stale edit, then verify.",
      model: %{provider: :test, id: "model"},
      operations:
        Enum.map(["coding.edit", "coding.read", "coding.verify"], fn name ->
          Agent.Spec.Operation.new!(name: name)
        end),
      runtime_defaults: %{max_model_turns: 8}
    )
  end

  defp batch_spec do
    Agent.Spec.new!(
      id: "operation_batch_recovery_agent",
      instructions: "Observe every batch result.",
      model: %{provider: :test, id: "model"},
      operations:
        Enum.map(["read_a", "stale_edit", "read_b"], fn name ->
          Agent.Spec.Operation.new!(name: name)
        end),
      runtime_defaults: %{max_model_turns: 4}
    )
  end
end
