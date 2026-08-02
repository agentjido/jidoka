defmodule Jidoka.Adapter.Jido.Scheduler do
  @moduledoc false

  @job_module Jido.Scheduler.Job

  @spec prepare(String.t(), String.t()) ::
          {:ok, %{cron: Crontab.CronExpression.t()}} | {:error, term()}
  def prepare(expression, timezone),
    do: apply(@job_module, :prepare_schedule, [expression, timezone])

  @spec next_at(Crontab.CronExpression.t(), String.t(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def next_at(cron, timezone, from),
    do: apply(@job_module, :next_scheduled_at, [cron, timezone, from])
end
