defmodule Jidoka.Workflow.Schedule do
  @moduledoc "One-time or recurring background workflow schedule contract."

  alias Jidoka.Adapter.Jido.Scheduler
  alias Jidoka.Schema
  alias Jidoka.Workflow.RetryPolicy

  @overlap_policies [:skip, :allow]
  @misfire_policies [:skip, :run_once]
  @cancellation_policies [:future_only, :future_and_active]

  @enforce_keys [
    :id,
    :workflow,
    :input,
    :trigger,
    :timezone,
    :overlap,
    :misfire,
    :misfire_grace_ms,
    :cancellation,
    :retry,
    :run_opts,
    :enabled,
    :next_at
  ]
  defstruct [
    :id,
    :workflow,
    :input,
    :trigger,
    :timezone,
    :overlap,
    :misfire,
    :misfire_grace_ms,
    :cancellation,
    :retry,
    :run_opts,
    :enabled,
    :next_at,
    :cron
  ]

  @type trigger :: {:at, DateTime.t()} | {:cron, String.t()}
  @type t :: %__MODULE__{
          id: String.t(),
          workflow: module(),
          input: map(),
          trigger: trigger(),
          timezone: String.t(),
          overlap: :skip | :allow,
          misfire: :skip | :run_once,
          misfire_grace_ms: non_neg_integer(),
          cancellation: :future_only | :future_and_active,
          retry: RetryPolicy.t() | nil,
          run_opts: keyword(),
          enabled: boolean(),
          next_at: DateTime.t() | nil,
          cron: Crontab.CronExpression.t() | nil
        }

  @doc "Builds and validates one schedule."
  @spec new(keyword() | map(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, attrs} <- normalize_attrs(attrs),
         {:ok, id} <- normalize_id(get(attrs, :id), opts),
         {:ok, workflow} <- normalize_workflow(get(attrs, :workflow)),
         {:ok, input} <- normalize_input(get(attrs, :input, %{})),
         {:ok, timezone} <- normalize_timezone(get(attrs, :timezone, "Etc/UTC")),
         {:ok, trigger, cron, next_at} <- normalize_trigger(get(attrs, :trigger), timezone, now),
         {:ok, overlap} <- enum_policy(:overlap, get(attrs, :overlap, :skip), @overlap_policies),
         {:ok, misfire} <- enum_policy(:misfire, get(attrs, :misfire, :run_once), @misfire_policies),
         {:ok, misfire_grace_ms} <- normalize_grace(get(attrs, :misfire_grace_ms, 1_000)),
         {:ok, cancellation} <-
           enum_policy(
             :cancellation,
             get(attrs, :cancellation, :future_only),
             @cancellation_policies
           ),
         {:ok, retry} <- RetryPolicy.new(get(attrs, :retry, max_attempts: 1)),
         {:ok, run_opts} <- normalize_run_opts(get(attrs, :run_opts, [])),
         {:ok, enabled} <- normalize_enabled(get(attrs, :enabled, true)) do
      {:ok,
       %__MODULE__{
         id: id,
         workflow: workflow,
         input: input,
         trigger: trigger,
         timezone: timezone,
         overlap: overlap,
         misfire: misfire,
         misfire_grace_ms: misfire_grace_ms,
         cancellation: cancellation,
         retry: retry,
         run_opts: run_opts,
         enabled: enabled,
         next_at: next_at,
         cron: cron
       }}
    end
  end

  @doc "Returns the next trigger time after a completed trigger."
  @spec advance(t(), DateTime.t()) :: {:ok, t()} | {:error, term()}
  def advance(%__MODULE__{trigger: {:at, _at}} = schedule, _from) do
    {:ok, %{schedule | enabled: false, next_at: nil}}
  end

  def advance(%__MODULE__{trigger: {:cron, _expression}} = schedule, from) do
    with {:ok, next_at} <- Scheduler.next_at(schedule.cron, schedule.timezone, from) do
      {:ok, %{schedule | next_at: next_at}}
    end
  end

  @doc "Returns the supported overlap policies."
  @spec overlap_policies() :: [:skip | :allow]
  def overlap_policies, do: @overlap_policies

  @doc "Returns the supported misfire policies."
  @spec misfire_policies() :: [:skip | :run_once]
  def misfire_policies, do: @misfire_policies

  @doc "Returns the supported schedule cancellation policies."
  @spec cancellation_policies() :: [:future_only | :future_and_active]
  def cancellation_policies, do: @cancellation_policies

  defp normalize_trigger({:at, %DateTime{} = at}, _timezone, _now), do: {:ok, {:at, at}, nil, at}

  defp normalize_trigger({:cron, expression}, timezone, now) when is_binary(expression) do
    with {:ok, prepared} <- Scheduler.prepare(expression, timezone),
         {:ok, local_now} <- DateTime.shift_zone(now, timezone, time_zone_database()),
         {:ok, next_at} <- Scheduler.next_at(prepared.cron, timezone, local_now) do
      {:ok, {:cron, expression}, prepared.cron, next_at}
    end
  end

  defp normalize_trigger(trigger, _timezone, _now), do: {:error, {:invalid_schedule_trigger, trigger}}

  defp normalize_workflow(workflow) when is_atom(workflow) do
    case Jidoka.Workflow.definition(workflow) do
      {:ok, %{mode: :dsl}} -> {:ok, workflow}
      {:ok, spec} -> {:error, {:scheduled_workflow_requires_dsl, spec.id}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_workflow(workflow), do: {:error, {:invalid_scheduled_workflow, workflow}}

  defp normalize_id(nil, opts), do: Jidoka.Id.generate("schedule", Keyword.get(opts, :id_generator))
  defp normalize_id(id, _opts) when is_binary(id) and id != "", do: {:ok, id}
  defp normalize_id(id, _opts), do: {:error, {:invalid_schedule_id, id}}

  defp normalize_input(input) when is_map(input), do: {:ok, input}

  defp normalize_input(input) when is_list(input) do
    if Keyword.keyword?(input), do: {:ok, Map.new(input)}, else: {:error, {:invalid_schedule_input, input}}
  end

  defp normalize_input(input), do: {:error, {:invalid_schedule_input, input}}

  defp normalize_timezone(timezone) when is_binary(timezone) and timezone != "" do
    case DateTime.now(timezone, time_zone_database()) do
      {:ok, _now} -> {:ok, timezone}
      {:error, reason} -> {:error, {:invalid_schedule_timezone, timezone, reason}}
    end
  end

  defp normalize_timezone(timezone), do: {:error, {:invalid_schedule_timezone, timezone}}

  defp normalize_grace(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp normalize_grace(value), do: {:error, {:invalid_schedule_misfire_grace, value}}

  defp enum_policy(field, value, allowed) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid_schedule_policy, field, value}}
  end

  defp normalize_run_opts(opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) -> {:error, {:invalid_schedule_run_opts, opts}}
      Keyword.has_key?(opts, :run_id) -> {:error, :scheduled_run_id_is_generated}
      true -> {:ok, opts}
    end
  end

  defp normalize_run_opts(opts), do: {:error, {:invalid_schedule_run_opts, opts}}

  defp normalize_enabled(value) when is_boolean(value), do: {:ok, value}
  defp normalize_enabled(value), do: {:error, {:invalid_schedule_enabled, value}}

  defp normalize_attrs(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: {:ok, Schema.normalize_attrs(attrs)},
      else: {:error, {:invalid_schedule_attributes, attrs}}
  end

  defp normalize_attrs(%{} = attrs), do: {:ok, Schema.normalize_attrs(attrs)}
  defp normalize_attrs(attrs), do: {:error, {:invalid_schedule_attributes, attrs}}

  defp get(attrs, key, default \\ nil), do: Schema.get_key(attrs, key, default)

  defp time_zone_database do
    Application.get_env(:jido, :time_zone_database, TimeZoneInfo.TimeZoneDatabase)
  end
end
