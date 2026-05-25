defmodule Jidoka.Schedule do
  @moduledoc """
  First-class scheduled agent turns and workflow runs for Jidoka.

  A schedule is a small runtime contract: when a cron expression fires,
  `Jidoka.Schedule.Manager` resolves the target and runs either
  `Jidoka.chat/3` or `Jidoka.Workflow.run/3`. This keeps scheduled work on the
  same path as normal agent turns, including context validation, hooks,
  guardrails, structured output, tracing, and inspection.

  The beta scheduler is intentionally in-memory. Schedule declarations compile
  to metadata, while registered schedules, scheduler processes, active runs,
  and bounded run history live only in the running `Jidoka.Schedule.Manager`
  process. Restarting the manager drops dynamic registrations and history
  unless the application re-registers schedule metadata during boot.

  Treat `history` as diagnostics, not an audit log. Durable schedule storage,
  recovery, and run journals belong to a later durability layer or to the
  application's runtime boundary.
  """

  @default_timezone "Etc/UTC"
  @default_timeout 30_000
  @valid_kinds [:agent, :workflow]
  @valid_overlap [:skip, :allow]

  @type callback :: (-> term()) | {module(), atom(), [term()]}
  @type resolvable(term_type) :: term_type | callback()
  @type target :: pid() | String.t() | module() | Jidoka.Session.t()

  @type t :: %__MODULE__{
          id: String.t(),
          kind: :agent | :workflow,
          target: target(),
          agent_id: String.t() | nil,
          runtime: module(),
          cron: String.t(),
          timezone: String.t(),
          prompt: resolvable(String.t()) | nil,
          input: resolvable(map() | keyword()) | nil,
          context: resolvable(map() | keyword()),
          conversation: String.t() | nil,
          opts: keyword(),
          start_opts: keyword(),
          timeout: pos_integer(),
          overlap: :skip | :allow,
          enabled?: boolean(),
          status: atom(),
          scheduler_pid: pid() | nil,
          running?: boolean(),
          run_count: non_neg_integer(),
          skip_count: non_neg_integer(),
          last_started_at_ms: integer() | nil,
          last_completed_at_ms: integer() | nil,
          last_status: atom() | nil,
          last_result: String.t() | nil,
          last_error: String.t() | nil,
          history: [map()]
        }

  defstruct [
    :id,
    :target,
    :agent_id,
    :cron,
    :prompt,
    :input,
    :conversation,
    :scheduler_pid,
    :last_started_at_ms,
    :last_completed_at_ms,
    :last_status,
    :last_result,
    :last_error,
    kind: :agent,
    runtime: Jidoka.Runtime,
    timezone: @default_timezone,
    context: %{},
    opts: [],
    start_opts: [],
    timeout: @default_timeout,
    overlap: :skip,
    enabled?: true,
    status: :scheduled,
    running?: false,
    run_count: 0,
    skip_count: 0,
    history: []
  ]

  @doc """
  Builds and validates a schedule.
  """
  @spec new(target(), keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(target, opts) when is_list(opts) do
    with {:ok, kind} <- normalize_kind(Keyword.get(opts, :kind, :agent)),
         {:ok, id} <- normalize_id(Keyword.get(opts, :id)),
         {:ok, cron} <- normalize_required_string(Keyword.get(opts, :cron), :cron),
         {:ok, timezone} <- normalize_timezone(Keyword.get(opts, :timezone, @default_timezone)),
         {:ok, overlap} <- normalize_overlap(Keyword.get(opts, :overlap, :skip)),
         {:ok, enabled?} <-
           normalize_boolean(Keyword.get(opts, :enabled?, Keyword.get(opts, :enabled, true)), :enabled?),
         {:ok, timeout} <- normalize_timeout(Keyword.get(opts, :timeout, @default_timeout)),
         {:ok, agent_id} <- normalize_schedule_agent_id(target, Keyword.get(opts, :agent_id)),
         {:ok, conversation} <- normalize_optional_string(Keyword.get(opts, :conversation), :conversation),
         {:ok, prompt} <- normalize_prompt(kind, Keyword.get(opts, :prompt)),
         {:ok, input} <- normalize_input(kind, Keyword.get(opts, :input)),
         {:ok, context} <- normalize_context_source(Keyword.get(opts, :context, %{})),
         {:ok, runtime} <- normalize_runtime(Keyword.get(opts, :runtime, Jidoka.Runtime)),
         {:ok, schedule_opts} <- normalize_keyword(Keyword.get(opts, :opts, Keyword.get(opts, :chat_opts, [])), :opts),
         {:ok, start_opts} <- normalize_keyword(Keyword.get(opts, :start_opts, []), :start_opts) do
      {:ok,
       %__MODULE__{
         id: id,
         kind: kind,
         target: target,
         agent_id: agent_id,
         runtime: runtime,
         cron: cron,
         timezone: timezone,
         prompt: prompt,
         input: input,
         context: context,
         conversation: conversation,
         opts: schedule_opts,
         start_opts: start_opts,
         timeout: timeout,
         overlap: overlap,
         enabled?: enabled?
       }}
    end
  end

  @doc false
  @spec default_timezone() :: String.t()
  def default_timezone, do: @default_timezone

  @doc false
  @spec put_scheduler_pid(t(), pid() | nil) :: t()
  def put_scheduler_pid(%__MODULE__{} = schedule, pid) when is_pid(pid) or is_nil(pid) do
    %{schedule | scheduler_pid: pid}
  end

  @doc false
  @spec starting(t(), integer()) :: t()
  def starting(%__MODULE__{} = schedule, started_at_ms) when is_integer(started_at_ms) do
    %{schedule | running?: true, status: :running, last_started_at_ms: started_at_ms}
  end

  @doc false
  @spec record_run(t(), map(), pos_integer()) :: t()
  def record_run(%__MODULE__{} = schedule, %{status: status} = run, history_limit)
      when is_integer(history_limit) and history_limit > 0 do
    completed_at_ms = Map.get(run, :completed_at_ms)
    result_preview = Map.get(run, :result_preview)
    error_preview = Map.get(run, :error_preview)

    %{
      schedule
      | running?: false,
        status: idle_status(schedule),
        run_count: schedule.run_count + run_count_increment(status),
        skip_count: schedule.skip_count + skip_count_increment(status),
        last_completed_at_ms: completed_at_ms,
        last_status: status,
        last_result: result_preview,
        last_error: error_preview,
        history: Enum.take([run | schedule.history], history_limit)
    }
  end

  defp run_count_increment(:skipped), do: 0
  defp run_count_increment(_status), do: 1

  defp skip_count_increment(:skipped), do: 1
  defp skip_count_increment(_status), do: 0

  defp idle_status(%__MODULE__{enabled?: false}), do: :disabled
  defp idle_status(%__MODULE__{}), do: :scheduled

  defp normalize_kind(kind) when kind in @valid_kinds, do: {:ok, kind}

  defp normalize_kind(kind) do
    {:error,
     Jidoka.Error.validation_error("Invalid schedule kind #{inspect(kind)}.",
       field: :kind,
       value: kind,
       details: %{reason: :invalid_schedule_kind, expected: @valid_kinds}
     )}
  end

  defp normalize_id(value), do: normalize_required_string(value, :id)

  defp normalize_optional_id(nil), do: {:ok, nil}
  defp normalize_optional_id(value), do: normalize_required_string(value, :agent_id)

  defp normalize_schedule_agent_id(%Jidoka.Session{agent_id: agent_id}, nil), do: {:ok, agent_id}

  defp normalize_schedule_agent_id(%Jidoka.Session{agent_id: agent_id}, value) do
    with {:ok, explicit_agent_id} <- normalize_optional_id(value) do
      if explicit_agent_id == agent_id do
        {:ok, agent_id}
      else
        {:error,
         Jidoka.Error.validation_error("Session schedule agent_id must match the session agent id.",
           field: :agent_id,
           value: explicit_agent_id,
           details: %{reason: :session_agent_id_mismatch, expected: agent_id}
         )}
      end
    end
  end

  defp normalize_schedule_agent_id(_target, value), do: normalize_optional_id(value)

  defp normalize_required_string(value, field) when is_atom(value),
    do: normalize_required_string(Atom.to_string(value), field)

  defp normalize_required_string(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> missing_string_error(field, value)
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_required_string(value, field), do: missing_string_error(field, value)

  defp normalize_optional_string(nil, _field), do: {:ok, nil}

  defp normalize_optional_string(value, _field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_optional_string(value, field) do
    {:error,
     Jidoka.Error.validation_error("Schedule #{field} must be a string.",
       field: field,
       value: value,
       details: %{reason: :invalid_schedule_option}
     )}
  end

  defp missing_string_error(field, value) do
    {:error,
     Jidoka.Error.validation_error("Schedule #{field} must be a non-empty string.",
       field: field,
       value: value,
       details: %{reason: :invalid_schedule_option}
     )}
  end

  defp normalize_timezone(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, @default_timezone}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_timezone(value) do
    {:error,
     Jidoka.Error.validation_error("Schedule timezone must be a string.",
       field: :timezone,
       value: value,
       details: %{reason: :invalid_schedule_option}
     )}
  end

  defp normalize_overlap(overlap) when overlap in @valid_overlap, do: {:ok, overlap}

  defp normalize_overlap(overlap) do
    {:error,
     Jidoka.Error.validation_error("Invalid schedule overlap policy #{inspect(overlap)}.",
       field: :overlap,
       value: overlap,
       details: %{reason: :invalid_schedule_overlap, expected: @valid_overlap}
     )}
  end

  defp normalize_boolean(value, _field) when is_boolean(value), do: {:ok, value}

  defp normalize_boolean(value, field) do
    {:error,
     Jidoka.Error.validation_error("Schedule #{field} must be a boolean.",
       field: field,
       value: value,
       details: %{reason: :invalid_schedule_option}
     )}
  end

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_timeout(value) do
    {:error,
     Jidoka.Error.validation_error("Schedule timeout must be a positive integer.",
       field: :timeout,
       value: value,
       details: %{reason: :invalid_schedule_option}
     )}
  end

  defp normalize_prompt(:agent, prompt) when is_binary(prompt) or is_function(prompt, 0), do: {:ok, prompt}

  defp normalize_prompt(:agent, {module, function, args} = prompt)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: {:ok, prompt}

  defp normalize_prompt(:workflow, nil), do: {:ok, nil}

  defp normalize_prompt(:agent, prompt) do
    {:error,
     Jidoka.Error.validation_error("Agent schedules require `prompt:` as a string, zero-arity function, or MFA tuple.",
       field: :prompt,
       value: prompt,
       details: %{reason: :invalid_schedule_prompt}
     )}
  end

  defp normalize_prompt(_kind, prompt), do: {:ok, prompt}

  defp normalize_input(:workflow, nil), do: {:ok, %{}}
  defp normalize_input(:workflow, input), do: normalize_context_source(input)
  defp normalize_input(:agent, nil), do: {:ok, nil}
  defp normalize_input(:agent, input), do: {:ok, input}

  defp normalize_context_source(value) when is_map(value) or is_function(value, 0), do: {:ok, value}

  defp normalize_context_source(value) when is_list(value),
    do: if(Keyword.keyword?(value), do: {:ok, value}, else: context_error(value))

  defp normalize_context_source({module, function, args} = value)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: {:ok, value}

  defp normalize_context_source(value), do: context_error(value)

  defp context_error(value) do
    {:error,
     Jidoka.Error.validation_error(
       "Schedule context/input must be a map, keyword list, zero-arity function, or MFA tuple.",
       field: :context,
       value: value,
       details: %{reason: :invalid_schedule_context}
     )}
  end

  defp normalize_runtime(runtime) when is_atom(runtime), do: {:ok, runtime}

  defp normalize_runtime(runtime) do
    {:error,
     Jidoka.Error.validation_error("Schedule runtime must be a module.",
       field: :runtime,
       value: runtime,
       details: %{reason: :invalid_schedule_runtime}
     )}
  end

  defp normalize_keyword(value, _field) when is_list(value) do
    if Keyword.keyword?(value), do: {:ok, value}, else: keyword_error(value)
  end

  defp normalize_keyword(value, field) do
    {:error,
     Jidoka.Error.validation_error("Schedule #{field} must be a keyword list.",
       field: field,
       value: value,
       details: %{reason: :invalid_schedule_option}
     )}
  end

  defp keyword_error(value) do
    {:error,
     Jidoka.Error.validation_error("Schedule options must be a keyword list.",
       field: :opts,
       value: value,
       details: %{reason: :invalid_schedule_option}
     )}
  end
end
