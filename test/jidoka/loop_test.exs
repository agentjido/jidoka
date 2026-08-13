defmodule Jidoka.LoopTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Loop
  alias Jidoka.Runtime.Limits
  alias Jidoka.Session.Sequence

  test "counts one independent group and one dependent sequence exactly" do
    llm = fn _intent, %Effect.Journal{} = journal, context ->
      completed_operation_names =
        journal.results
        |> Enum.filter(fn {_id, result} -> result.kind == :operation end)
        |> Enum.map(fn {intent_id, _result} ->
          intent = Map.fetch!(journal.intents, intent_id)
          Effect.OperationRequest.new!(intent.payload).name
        end)

      completed_operations = MapSet.new(completed_operation_names)

      case {context.input, completed_operation_names} do
        {"parallel", []} ->
          {:ok,
           %{
             type: :operations,
             operations: [
               %{name: "read_a", arguments: %{}},
               %{name: "read_b", arguments: %{}},
               %{name: "read_c", arguments: %{}}
             ]
           }}

        {"parallel", _completed} ->
          {:ok, %{type: :final, content: "parallel complete"}}

        {"dependent", _completed} ->
          cond do
            not MapSet.member?(completed_operations, "read_a") ->
              {:ok, %{type: :operation, name: "read_a", arguments: %{}}}

            not MapSet.member?(completed_operations, "write_a") ->
              {:ok, %{type: :operation, name: "write_a", arguments: %{}}}

            true ->
              {:ok, %{type: :final, content: "dependent complete"}}
          end
      end
    end

    operation = fn intent, _journal, _context ->
      request = Effect.OperationRequest.new!(intent.payload)
      {:ok, %{operation: request.name}}
    end

    {:ok, session} = Jidoka.Session.start(spec(), "loop-counts")

    assert {:ok, %Sequence.Result{status: :completed} = result} =
             Jidoka.Session.run_sequence(session, ["parallel", "dependent"],
               llm: llm,
               operations: operation,
               max_parallel_operations: 3
             )

    assert %Loop.Counts{
             user_turns: 2,
             model_steps: 5,
             tool_call_groups: 3,
             tool_calls: 5
           } = Loop.counts(Enum.map(result.steps, & &1.result))

    assert %Limits.Observed{
             user_turns: 2,
             model_steps: 5,
             model_turns: 5,
             tool_call_groups: 3,
             tool_calls: 5
           } = result.limits.observed
  end

  defp spec do
    Jidoka.agent!(
      id: "loop_count_agent",
      instructions: "Use the operations, then answer.",
      model: %{provider: :test, id: "model"},
      operations: Enum.map(["read_a", "read_b", "read_c", "write_a"], &Operation.new!(name: &1)),
      runtime_defaults: %{max_model_turns: 4}
    )
  end
end
