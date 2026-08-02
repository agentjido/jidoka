defmodule JidokaExamples.DurableRefund.Scenario do
  @moduledoc false

  alias Jidoka.Stream
  alias JidokaExamples.DurableRefund.Scenarios.AsyncExecution
  alias JidokaExamples.DurableRefund.Scenarios.DurableRecovery
  alias JidokaExamples.DurableRefund.Scenarios.ExecutionLimits
  alias JidokaExamples.DurableRefund.Scenarios.SafeFork

  def run(opts \\ []) do
    opts = Keyword.drop(opts, [:credential_ref])

    with {:ok, async} <- async_streaming(opts),
         {:ok, cancellation} <- typed_cancellation(opts),
         {:ok, limits} <- bounded_execution(opts),
         {:ok, recovery} <- durable_recovery(opts),
         {:ok, fork} <- safe_fork(opts) do
      {:ok,
       %{
         async_streaming: %{
           answer: async.answer,
           event_count: length(async.events),
           terminal_event_count: Enum.count(async.events, &Stream.terminal?/1),
           thinking: async.thinking
         },
         cancellation: %{
           capability_alive?: cancellation.capability_alive?,
           forced?: cancellation.cancellation.forced?,
           reason: cancellation.cancellation.reason,
           terminal_event_count: length(cancellation.terminal_events)
         },
         execution_limits: limits,
         durable_recovery: %{
           answer: recovery.answer,
           operation_calls: recovery.operation_calls,
           session_revision: recovery.session.revision,
           status: recovery.session.status
         },
         safe_fork: %{
           branch_answer: fork.branch_answer,
           branch_id: fork.branch.session_id,
           lineage: Jidoka.project(fork.branch.lineage),
           source_answer: fork.source_answer,
           source_id: fork.source.session_id
         }
       }}
    end
  end

  def async_streaming(opts \\ []), do: AsyncExecution.stream(opts)
  def typed_cancellation(opts \\ []), do: AsyncExecution.cancel(opts)
  def bounded_execution(opts \\ []), do: ExecutionLimits.run(opts)
  def durable_recovery(opts \\ []), do: DurableRecovery.run(opts)
  def safe_fork(opts \\ []), do: SafeFork.run(opts)
end
