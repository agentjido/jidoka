defmodule Jidoka.Parity.DeterministicWorkflowCompositionTest do
  use Jidoka.ParityCase, parity: :deterministic_workflow_composition

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Turn
  alias Jidoka.Workflow

  import Jidoka.TestSupport, only: [count_results: 2, operation_then_final_llm: 3]

  defmodule WorkflowFns do
    @moduledoc false

    alias Jidoka.Schema

    def process_item(%{index: index, value: value}, context) do
      if Jidoka.Context.get(context, :completion_mode, :immediate) == :barrier do
        test_pid = Jidoka.Context.get(context, :test_pid)
        completion_log = Jidoka.Context.get(context, :completion_log)
        send(test_pid, {:composition_item_started, index, self()})

        receive do
          {:release_composition_item, ^index} ->
            Elixir.Agent.update(completion_log, &(&1 ++ [index]))
            send(test_pid, {:composition_item_finishing, index})
        after
          2_000 ->
            raise "timed out waiting to release composition item #{index}"
        end
      end

      {:ok, %{index: index, value: value, processed: value * 2}}
    end

    def eligible_path(_params, context) do
      record_branch(context, :eligible)
      {:ok, %{path: :eligible}}
    end

    def ineligible_path(_params, context) do
      record_branch(context, :ineligible)
      {:ok, %{path: :ineligible}}
    end

    def summarize(%{items: items, path: path}, context) do
      context
      |> Jidoka.Context.get(:reduction_count)
      |> Elixir.Agent.update(&(&1 + 1))

      {:ok,
       %{
         path: Schema.get_key(path, :path),
         ordered_values: Enum.map(items, &Schema.get_key(&1, :value)),
         processed_total: Enum.sum(Enum.map(items, &Schema.get_key(&1, :processed)))
       }}
    end

    def fail_then_succeed(%{value: value}, context) do
      attempt =
        context
        |> Jidoka.Context.get(:retry_success_count)
        |> Elixir.Agent.get_and_update(&{&1 + 1, &1 + 1})

      if attempt < 3 do
        {:error, {:not_yet, attempt}}
      else
        {:ok, %{value: value, attempt: attempt}}
      end
    end

    def always_fail(_params, context) do
      context
      |> Jidoka.Context.get(:retry_exhaustion_count)
      |> Elixir.Agent.update(&(&1 + 1))

      {:error, :still_failing}
    end

    defp record_branch(context, branch) do
      context
      |> Jidoka.Context.get(:branch_log)
      |> Elixir.Agent.update(&(&1 ++ [branch]))
    end
  end

  defmodule CompositionWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id(:deterministic_workflow_composition)
      description "Branches, maps concurrently, and reduces in input order."

      input Zoi.object(%{
              items: Zoi.array(Zoi.integer()),
              eligible: Zoi.boolean()
            })
    end

    steps do
      gate(:eligible, condition: input(:eligible))

      map(:process_items,
        over: input(:items),
        function: {WorkflowFns, :process_item, 2},
        input: %{index: index(), value: item()},
        max_concurrency: 3
      )

      function :eligible_path, {WorkflowFns, :eligible_path, 2},
        when: from(:eligible),
        input: %{}

      function :ineligible_path, {WorkflowFns, :ineligible_path, 2},
        unless: from(:eligible),
        input: %{}

      reduce(:summarize,
        over: from(:process_items),
        using: {WorkflowFns, :summarize, 2},
        input: %{
          items: items(),
          path: coalesce([maybe_from(:eligible_path), maybe_from(:ineligible_path)])
        }
      )
    end

    output from(:summarize)
  end

  defmodule RetrySuccessWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id(:bounded_retry_success)
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      function :flaky, {WorkflowFns, :fail_then_succeed, 2},
        input: %{value: input(:value)},
        retry: [max_attempts: 3, backoff: [type: :fixed, min: 0, max: 0]]
    end

    output from(:flaky)
  end

  defmodule RetryExhaustionWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id(:bounded_retry_exhaustion)
      input Zoi.object(%{})
    end

    steps do
      function :always_fail, {WorkflowFns, :always_fail, 2},
        input: %{},
        retry: [max_attempts: 2, backoff: [type: :fixed, min: 0, max: 0]]
    end

    output from(:always_fail)
  end

  defmodule CompositionAgent do
    @moduledoc false

    use Jidoka.Agent

    alias Jidoka.Parity.DeterministicWorkflowCompositionTest.CompositionWorkflow

    agent :deterministic_workflow_composition_agent do
      model %{provider: :test, id: "scripted-model"}
      instructions "Use compose_workflow for deterministic composition requests."
    end

    tools do
      workflow CompositionWorkflow,
        as: :compose_workflow,
        async: true,
        max_concurrency: 3,
        forward_context: :public,
        result: :structured
    end
  end

  test "composes deterministic workflow behavior directly and as one agent operation" do
    branch_log = start_state([])
    completion_log = start_state([])
    reduction_count = start_state(0)
    retry_success_count = start_state(0)
    retry_exhaustion_count = start_state(0)
    test_pid = self()

    arguments = %{"items" => [3, 1, 2], "eligible" => true}

    direct_task =
      Task.async(fn ->
        Workflow.run(CompositionWorkflow, arguments,
          async: true,
          max_concurrency: 3,
          timeout: 5_000,
          context: %{
            branch_log: branch_log,
            completion_log: completion_log,
            completion_mode: :barrier,
            reduction_count: reduction_count,
            test_pid: test_pid
          }
        )
      end)

    workers = receive_workers(3)

    for index <- [2, 1, 0] do
      worker = Map.fetch!(workers, index)
      monitor = Process.monitor(worker)
      send(worker, {:release_composition_item, index})
      assert_receive {:composition_item_finishing, ^index}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    end

    expected_output = %{
      path: :eligible,
      ordered_values: [3, 1, 2],
      processed_total: 12
    }

    assert {:ok, ^expected_output} = Task.await(direct_task, 5_000)
    assert Elixir.Agent.get(completion_log, & &1) == [2, 1, 0]
    assert Elixir.Agent.get(branch_log, & &1) == [:eligible]
    assert Elixir.Agent.get(reduction_count, & &1) == 1

    Elixir.Agent.update(branch_log, fn _ -> [] end)

    assert {:ok, %{path: :ineligible, ordered_values: [], processed_total: 0}} =
             Workflow.run(CompositionWorkflow, %{items: [], eligible: false},
               async: true,
               max_concurrency: 3,
               context: %{
                 branch_log: branch_log,
                 completion_mode: :immediate,
                 reduction_count: reduction_count
               }
             )

    assert Elixir.Agent.get(branch_log, & &1) == [:ineligible]
    assert Elixir.Agent.get(reduction_count, & &1) == 2

    assert {:ok, %{value: 10, attempt: 3}} =
             Workflow.run(RetrySuccessWorkflow, %{value: 10}, context: %{retry_success_count: retry_success_count})

    assert Elixir.Agent.get(retry_success_count, & &1) == 3

    assert {:error, exhaustion_error} =
             Workflow.run(RetryExhaustionWorkflow, %{}, context: %{retry_exhaustion_count: retry_exhaustion_count})

    assert exhaustion_error.details.step == :always_fail
    assert exhaustion_error.details.cause == {:retry_exhausted, 2, :still_failing}
    assert Elixir.Agent.get(retry_exhaustion_count, & &1) == 2

    Elixir.Agent.update(branch_log, fn _ -> [] end)

    assert [%Operation{} = operation] = CompositionAgent.spec().operations
    assert operation.name == "compose_workflow"
    assert Operation.kind(operation) == :workflow
    assert operation.metadata["workflow"] == "deterministic_workflow_composition"

    request =
      Turn.Request.new!(
        input: "Compose these values deterministically.",
        context: %{
          branch_log: branch_log,
          completion_mode: :immediate,
          reduction_count: reduction_count
        }
      )

    llm = operation_then_final_llm("compose_workflow", arguments, "Workflow complete.")

    assert {:ok, %Turn.Result{content: "Workflow complete."} = result} =
             CompositionAgent.run_turn(request, llm: llm)

    assert [
             %Effect.OperationResult{
               operation: "compose_workflow",
               arguments: ^arguments,
               output: nested_output
             } = operation_result
           ] = result.agent_state.operation_results

    assert %{
             workflow: "deterministic_workflow_composition",
             operation: "compose_workflow",
             module: workflow_module,
             output: ^expected_output
           } = nested_output

    assert workflow_module == inspect(CompositionWorkflow)
    assert Elixir.Agent.get(branch_log, & &1) == [:eligible]
    assert Elixir.Agent.get(reduction_count, & &1) == 3

    assert [workflow_intent] =
             result.journal.intents
             |> Map.values()
             |> Enum.filter(&match?(%Effect.Intent{kind: :operation}, &1))

    assert workflow_intent.payload.name == "compose_workflow"
    assert workflow_intent.payload.arguments == arguments
    assert count_results(result.journal, :operation) == 1

    assert %Effect.Result{
             intent_id: workflow_intent_id,
             kind: :operation,
             status: :ok,
             output: journal_output
           } = Map.fetch!(result.journal.results, workflow_intent.id)

    assert workflow_intent_id == workflow_intent.id
    assert journal_output == operation_result.output
  end

  defp receive_workers(count), do: receive_workers(count, %{})
  defp receive_workers(0, workers), do: workers

  defp receive_workers(remaining, workers) do
    receive do
      {:composition_item_started, index, worker} ->
        receive_workers(remaining - 1, Map.put(workers, index, worker))
    after
      1_000 ->
        flunk("expected #{remaining} more composition map workers to start")
    end
  end

  defp start_state(initial) do
    {:ok, state} = Elixir.Agent.start_link(fn -> initial end)
    on_exit(fn -> if Process.alive?(state), do: Elixir.Agent.stop(state) end)
    state
  end
end
