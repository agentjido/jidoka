defmodule Jidoka.Parity.BoundedDynamicWorkflowLoopTest do
  use Jidoka.ParityCase, parity: :bounded_dynamic_workflow_loop

  alias Jidoka.Workflow
  alias Jidoka.Workflow.Loop.Result
  alias Jidoka.Workflow.Snapshot

  @moduletag :w04

  defmodule Functions do
    @moduledoc false

    def seed(%{items: items}, context) do
      context
      |> Jidoka.Context.get_runtime(:seed_calls)
      |> Elixir.Agent.update(&(&1 + 1))

      {:ok, %{pending: items, processed: []}}
    end

    def process(%{state: %{pending: []} = state}, _context), do: {:halt, state}

    def process(%{state: state, iteration: iteration}, context) do
      [item | pending] = state.pending
      created_work = if item == 1, do: [3], else: []

      next = %{
        pending: pending ++ created_work,
        processed: state.processed ++ [item]
      }

      if iteration == 1 and
           Elixir.Agent.get_and_update(
             Jidoka.Context.get_runtime(context, :suspend_once),
             &{&1, false}
           ) do
        {:suspend, next, created_work}
      else
        {:cont, next, created_work}
      end
    end

    def never_halt(%{state: state}, _context), do: {:cont, state}
  end

  defmodule DynamicLoopWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id :bounded_dynamic_loop
      input Zoi.object(%{items: Zoi.array(Zoi.integer())})
    end

    steps do
      function :seed, {Functions, :seed, 2}, input: %{items: input(:items)}

      loop(:process_queue,
        initial: from(:seed),
        using: {Functions, :process, 2},
        input: %{state: loop_state(), iteration: iteration()},
        max_iterations: 8
      )
    end

    output from(:process_queue)
  end

  defmodule ExhaustedLoopWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id :exhausted_bounded_loop
      input Zoi.object(%{})
    end

    steps do
      loop(:never_halts,
        initial: value(%{count: 0}),
        using: {Functions, :never_halt, 2},
        input: %{state: loop_state()},
        max_iterations: 3
      )
    end

    output from(:never_halts)
  end

  test "records runtime-created work and resumes from a serialized bounded cursor" do
    {:ok, seed_calls} = Elixir.Agent.start_link(fn -> 0 end)
    {:ok, suspend_once} = Elixir.Agent.start_link(fn -> true end)

    context =
      Jidoka.Context.from_data!(%{},
        runtime: %{seed_calls: seed_calls, suspend_once: suspend_once}
      )

    assert {:hibernate, %Snapshot{} = snapshot} =
             Workflow.run(DynamicLoopWorkflow, %{items: [1, 2]}, context: context)

    assert {:ok, cursor} = Snapshot.cursor(snapshot)
    assert cursor.next_iteration == 2
    assert cursor.state == %{pending: [3], processed: [1, 2]}
    assert Enum.flat_map(cursor.iterations, & &1.created_work) == [3]
    assert Elixir.Agent.get(seed_calls, & &1) == 1

    assert {:ok, binary} = Snapshot.serialize(snapshot)
    assert {:ok, %Snapshot{} = restored} = Snapshot.deserialize(binary)

    non_portable = put_in(restored.outcomes.process_queue.cursor.state, %{runtime: self()})

    assert {:error,
            {:non_serializable_workflow_snapshot_value, [:outcomes, :process_queue, :cursor, :state, :runtime], :pid}} =
             Snapshot.serialize(non_portable)

    changed_bound = put_in(restored.outcomes.process_queue.cursor.max_iterations, 9)

    assert {:error, {:workflow_loop_bound_changed, :process_queue, 9, 8}} =
             Workflow.resume(changed_bound)

    assert {:ok, %Result{} = result} = Workflow.resume(restored, context: context)
    assert result.value == %{pending: [], processed: [1, 2, 3]}
    assert result.created_work == [3]
    assert Enum.map(result.iterations, & &1.index) == [0, 1, 2, 3]
    assert Elixir.Agent.get(seed_calls, & &1) == 1

    assert %{graph: %{nodes: nodes}} = Jidoka.inspect(DynamicLoopWorkflow)

    assert %{
             kind: :loop,
             loop: %{max_iterations: 8},
             input: %{iteration: %{ref: :iteration}, state: %{ref: :loop_state}},
             output: :loop_result
           } = Enum.find(nodes, &(&1.name == :process_queue))
  end

  test "stops on the exact loop bound with an inspectable cursor" do
    assert {:error, error} = Workflow.run(ExhaustedLoopWorkflow, %{})

    assert %{details: %{cause: {:loop_limit_exceeded, cursor}}} = error
    assert cursor.step == :never_halts
    assert cursor.next_iteration == 3
    assert length(cursor.iterations) == 3
  end
end
