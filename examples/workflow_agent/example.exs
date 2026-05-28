defmodule JidokaExamples.WorkflowAgentExample do
  @behaviour JidokaExamples.Example

  alias JidokaExamples.Workflows.{MathAgent, MathWorkflow}

  @impl true
  def name, do: :workflow_agent

  @impl true
  def title, do: "Workflow Agent"

  @impl true
  def features, do: [:workflow, :schedule, :workflow_tool]

  @impl true
  def summary, do: "Runs a deterministic workflow directly, as a schedule, and as an agent capability."

  @impl true
  def run(opts \\ []) do
    case JidokaExamples.mode(opts) do
      :live -> run_live(opts)
      :verify -> run_verify(opts)
    end
  end

  defp run_verify(_opts) do
    {:ok, workflow_result} = MathWorkflow.run(%{value: 3})
    schedule_id = "example-math-#{System.unique_integer([:positive])}"

    {:ok, _schedule} =
      Jidoka.schedule_workflow(MathWorkflow,
        id: schedule_id,
        cron: "0 9 * * *",
        input: %{value: 5},
        enabled?: false
      )

    try do
      {:ok, scheduled_run} = Jidoka.run_schedule(schedule_id)

      {:ok,
       %{
         example: name(),
         mode: :verify,
         workflow_result: workflow_result,
         agent_tool_names: MathAgent.tool_names(),
         scheduled_status: scheduled_run.status,
         scheduled_result: scheduled_run.result
       }}
    after
      Jidoka.cancel_schedule(schedule_id)
    end
  end

  defp run_live(opts) do
    with {:ok, provider_env} <- JidokaExamples.require_live_provider(opts) do
      prompt = JidokaExamples.prompt(opts, "Use run_math with value 7 and explain the result in one sentence.")
      session = Jidoka.session(MathAgent, "workflow-live", context: %{actor_id: "user_live"})

      try do
        result = Jidoka.chat(session, prompt, timeout: 60_000)

        with {:ok, response} <- JidokaExamples.live_chat_summary(result) do
          {:ok,
           %{
             example: name(),
             mode: :live,
             provider_env: provider_env,
             response: response
           }}
        end
      after
        if pid = Jidoka.Session.whereis(session), do: Jidoka.stop_agent(pid)
      end
    end
  end
end
