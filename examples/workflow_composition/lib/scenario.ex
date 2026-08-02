defmodule JidokaExamples.WorkflowComposition.Scenario do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Workflow
  alias Jidoka.Workflow.{Background, Scheduler}
  alias JidokaExamples.WorkflowComposition.{
    Agent,
    FulfillmentWorkflow,
    ScriptedLLM,
    StaticMultiAgentWorkflow
  }

  @input %{
    expedited: true,
    items: [
      %{quantity: 1, sku: "starter_kit", unit_price: 25},
      %{quantity: 2, sku: "cable", unit_price: 5}
    ]
  }

  def sample_input, do: @input

  def direct_and_agent(opts \\ []) do
    observer = Keyword.get(opts, :observer)

    with {:ok, direct} <- run_direct(observer),
         {:ok, result} <- run_agent(observer),
         [%Effect.OperationResult{output: %{output: agent_output}}] <-
           result.agent_state.operation_results do
      {:ok,
       %{
         agent_answer: result.content,
         agent_output: agent_output,
         direct_output: direct,
         parity?: agent_output == direct
       }}
    else
      other -> {:error, {:workflow_example_failed, other}}
    end
  end

  def background(runner, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, "workflow_example_background")

    with_retry_context(opts, fn context ->
      with {:ok, ^run_id} <-
             Background.submit(runner, FulfillmentWorkflow, @input,
               run_id: run_id,
               context: context
             ),
           {:ok, run} <- Background.await(runner, run_id, timeout: 5_000),
           {:ok, events} <- Background.events(runner, run_id) do
        {:ok, %{events: events, run: run}}
      end
    end)
  end

  def scheduled(scheduler, runner, now, opts \\ []) do
    schedule_id = Keyword.get(opts, :schedule_id, "workflow_example_schedule")

    with_retry_context(opts, fn context ->
      with {:ok, schedule} <-
             Scheduler.add(scheduler, %{
               id: schedule_id,
               workflow: FulfillmentWorkflow,
               input: @input,
               trigger: {:at, now},
               timezone: "Etc/UTC",
               overlap: :skip,
               misfire: :run_once,
               cancellation: :future_only,
               retry: [max_attempts: 2],
               run_opts: [context: context]
             }),
           [trigger] <- Scheduler.trigger_due(scheduler, now),
           {:ok, run} <- Background.await(runner, trigger.run_id, timeout: 5_000) do
        {:ok, %{run: run, schedule: schedule, trigger: trigger}}
      else
        other -> {:error, {:scheduled_workflow_example_failed, other}}
      end
    end)
  end

  def static_multi_agent(opts \\ []) do
    observer = Keyword.get(opts, :observer)

    Workflow.run(StaticMultiAgentWorkflow, %{order_id: "A1001"},
      agent_opts: [llm: static_agent_model(observer)]
    )
  end

  defp run_direct(observer) do
    with_retry_context([observer: observer], fn context ->
      Workflow.run(FulfillmentWorkflow, @input,
        context: context,
        async: true,
        max_concurrency: 4
      )
    end)
  end

  defp run_agent(observer) do
    with_retry_context([observer: observer], fn context ->
      Jidoka.turn(Agent, "Fulfill the sample order.",
        context: Jidoka.Context.data(context),
        operation_context: context,
        llm: ScriptedLLM.capability(@input)
      )
    end)
  end

  defp static_agent_model(observer) do
    fn _intent, _journal, context ->
      stage = Jidoka.Context.get(context, :stage)
      notify(observer, {:static_agent_node_called, stage})

      case stage do
        :draft ->
          {:ok, %{type: :final, content: "Order A1001 is ready for priority fulfillment."}}

        :review ->
          {:ok,
           %{
             type: :final,
             content: "Approved: Order A1001 is ready for priority fulfillment."
           }}
      end
    end
  end

  defp with_retry_context(opts, fun) do
    {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)

    context =
      Jidoka.Context.from_data!(%{},
        runtime: %{
          observer: Keyword.get(opts, :observer),
          retry_counter: counter
        }
      )

    try do
      fun.(context)
    after
      if Process.alive?(counter), do: Elixir.Agent.stop(counter)
    end
  end

  defp notify(observer, message) when is_pid(observer), do: send(observer, message)
  defp notify(_observer, _message), do: :ok
end
