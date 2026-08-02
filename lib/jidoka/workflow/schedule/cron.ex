defmodule Jidoka.Workflow.Schedule.Cron do
  @moduledoc false

  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler

  @max_schedule_attempts 8

  @spec prepare(String.t(), String.t()) ::
          {:ok, %{cron: Crontab.CronExpression.t()}} | {:error, term()}
  def prepare(expression, timezone) when is_binary(expression) and is_binary(timezone) do
    with {:ok, cron} <- parse(expression),
         {:ok, now} <- now_in_timezone(timezone),
         {:ok, _next_at} <- next_at(cron, timezone, now) do
      {:ok, %{cron: cron}}
    end
  end

  @spec next_at(Crontab.CronExpression.t(), String.t(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def next_at(cron, timezone, from)
      when is_struct(cron, Crontab.CronExpression) and is_binary(timezone) and
             is_struct(from, DateTime) do
    do_next_at(cron, timezone, from, @max_schedule_attempts)
  end

  defp parse(expression) do
    Enum.reduce_while(parse_modes(expression), {:error, {:invalid_cron, expression}}, fn extended, _acc ->
      case Parser.parse(expression, extended) do
        {:ok, cron} -> {:halt, {:ok, cron}}
        {:error, reason} -> {:cont, {:error, {:invalid_cron, reason}}}
      end
    end)
  end

  defp parse_modes("@" <> _expression), do: [false]

  defp parse_modes(expression) do
    if expression |> String.split(~r/\s+/, trim: true) |> length() > 5 do
      [true, false]
    else
      [false, true]
    end
  end

  defp do_next_at(_cron, _timezone, _from, 0), do: {:error, :schedule_resolution_limit}

  defp do_next_at(cron, timezone, from, attempts_left) do
    with {:ok, next_naive} <- next_run_date(cron, from) do
      case DateTime.from_naive(next_naive, timezone, time_zone_database()) do
        {:ok, next_at} ->
          ensure_future(cron, timezone, next_at, from, attempts_left)

        {:ambiguous, _first, second} ->
          ensure_future(cron, timezone, second, from, attempts_left)

        {:gap, _before, after_datetime} ->
          do_next_at(cron, timezone, after_datetime, attempts_left - 1)

        {:error, reason} ->
          {:error, {:invalid_timezone, reason}}
      end
    end
  end

  defp next_run_date(cron, from) do
    case Scheduler.get_next_run_date(cron, DateTime.to_naive(from)) do
      {:ok, next_naive} -> {:ok, next_naive}
      {:error, reason} -> {:error, {:next_run_not_found, reason}}
    end
  rescue
    exception -> {:error, {:next_run_exception, Exception.message(exception)}}
  end

  defp ensure_future(cron, timezone, next_at, from, attempts_left) do
    case DateTime.compare(next_at, from) do
      :gt ->
        {:ok, next_at}

      _other ->
        with {:ok, next_from} <- advance_search_start(from, timezone) do
          do_next_at(cron, timezone, next_from, attempts_left - 1)
        end
    end
  end

  defp advance_search_start(from, timezone) do
    with {:ok, utc_datetime} <- DateTime.from_unix(DateTime.to_unix(from, :second) + 1, :second),
         {:ok, next_from} <- DateTime.shift_zone(utc_datetime, timezone, time_zone_database()) do
      {:ok, next_from}
    else
      {:error, reason} -> {:error, {:invalid_timezone, reason}}
    end
  end

  defp now_in_timezone(timezone) do
    case DateTime.now(timezone, time_zone_database()) do
      {:ok, now} -> {:ok, now}
      {:error, reason} -> {:error, {:invalid_timezone, reason}}
    end
  end

  defp time_zone_database do
    Application.get_env(:jido, :time_zone_database, TimeZoneInfo.TimeZoneDatabase)
  end
end
