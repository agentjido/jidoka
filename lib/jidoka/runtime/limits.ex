defmodule Jidoka.Runtime.Limits do
  @moduledoc """
  Resolves and evaluates provider-neutral runtime limits.

  Callers can use `:runtime_limits` to reduce a turn plan. Jidoka keeps the
  plan limits as hard upper bounds. A sequence result contains portable
  applied, observed, and exceeded evidence.
  """

  alias Jidoka.Effect
  alias Jidoka.Runtime.Limits.{Applied, Evidence, Exceeded, Ledger, Observed}
  alias Jidoka.Schema
  alias Jidoka.Session.Sequence
  alias Jidoka.Turn

  @keys [
    :max_model_turns,
    :turn_timeout_ms,
    :capability_timeout_ms,
    :sequence_timeout_ms,
    :max_provider_attempts,
    :max_tool_calls_per_group,
    :max_tool_calls_per_turn,
    :max_recovery_steps,
    :max_observation_bytes,
    :max_result_repairs,
    :max_total_tokens,
    :max_total_cost,
    :environment
  ]

  @doc "Resolves runtime options against the fixed limits in a turn plan."
  @spec resolve(Turn.Plan.t(), keyword()) :: {:ok, Applied.t()} | {:error, term()}
  def resolve(%Turn.Plan{} = plan, opts) when is_list(opts) do
    case Keyword.get(opts, :runtime_limits, %{}) do
      %Applied{} = applied -> tighten_plan_limits(applied, plan)
      attrs when is_list(attrs) or is_map(attrs) -> resolve_attrs(plan, attrs, opts)
      other -> {:error, {:invalid_runtime_limits, other}}
    end
  end

  @doc "Applies model-turn and turn-time limits to an executable plan."
  @spec apply_plan(Turn.Plan.t(), Applied.t()) :: Turn.Plan.t()
  def apply_plan(%Turn.Plan{} = plan, %Applied{} = applied) do
    %Turn.Plan{
      plan
      | max_model_turns: min(plan.max_model_turns, applied.max_model_turns),
        timeout_ms: min(plan.timeout_ms, applied.turn_timeout_ms)
    }
  end

  @doc "Reserves one complete operation group before any operation starts."
  @spec reserve_operation_group(Turn.State.t(), [Effect.Intent.t()]) ::
          {:ok, Turn.State.t()} | {:error, {:runtime_limit_exceeded, Exceeded.t()}}
  def reserve_operation_group(%Turn.State{} = state, intents) when is_list(intents) do
    %Ledger{} = ledger = ledger(state)
    group_id = Effect.OperationGroup.new!(intents).id
    new_intents = Enum.reject(intents, &(&1.id in ledger.tool_call_ids))

    recoveries =
      Enum.filter(intents, fn intent ->
        Effect.Journal.incomplete_intent?(state.journal, intent) and
          intent.id not in ledger.recovery_intent_ids
      end)

    with :ok <- check_max(state, :tool_calls_per_group, length(intents)),
         :ok <- check_max(state, :tool_calls_per_turn, ledger.tool_calls + length(new_intents)),
         :ok <- check_max(state, :recovery_steps, ledger.recovery_steps + length(recoveries)) do
      ledger = %Ledger{
        ledger
        | tool_call_groups: ledger.tool_call_groups + if(group_id in ledger.operation_group_ids, do: 0, else: 1),
          tool_calls: ledger.tool_calls + length(new_intents),
          recovery_steps: ledger.recovery_steps + length(recoveries),
          operation_group_ids: Enum.uniq(ledger.operation_group_ids ++ [group_id]),
          tool_call_ids: Enum.uniq(ledger.tool_call_ids ++ Enum.map(new_intents, & &1.id)),
          recovery_intent_ids: Enum.uniq(ledger.recovery_intent_ids ++ Enum.map(recoveries, & &1.id))
      }

      {:ok, %Turn.State{state | limit_ledger: Map.from_struct(ledger)}}
    end
  end

  @doc "Records one effect result and enforces result-size limits."
  @spec record_effect_result(Turn.State.t(), Effect.Result.t()) ::
          {:ok, Turn.State.t()}
          | {:error, {:runtime_limit_exceeded, Exceeded.t()}, Turn.State.t()}
  def record_effect_result(%Turn.State{} = state, %Effect.Result{} = result) do
    ledger = add_effect_result(ledger(state), result)
    state = %Turn.State{state | limit_ledger: Map.from_struct(ledger)}

    case check_max(state, :observation_bytes, ledger.observation_bytes) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc "Checks budgets that must have capacity before the next model step."
  @spec check_before_model_step(Turn.State.t()) ::
          :ok | {:error, {:runtime_limit_exceeded, Exceeded.t()}}
  def check_before_model_step(%Turn.State{} = state) do
    ledger = ledger(state)

    [
      check_capacity(state, :provider_attempts, ledger.provider_attempts),
      check_capacity(state, :total_tokens, ledger.total_tokens),
      check_capacity(state, :total_cost, ledger.total_cost)
    ]
    |> Enum.find(:ok, &match?({:error, _reason}, &1))
  end

  @doc "Checks one provider call against the aggregate turn budget."
  @spec check_provider_attempt(Effect.Journal.t(), non_neg_integer(), Applied.t() | nil) ::
          :ok | {:error, {:runtime_limit_exceeded, Exceeded.t()}}
  def check_provider_attempt(%Effect.Journal{} = journal, current_attempts, %Applied{} = applied)
      when is_integer(current_attempts) and current_attempts >= 0 do
    observed = provider_attempts(journal) + current_attempts

    if is_integer(applied.max_provider_attempts) and observed >= applied.max_provider_attempts do
      exceeded(:provider_attempts, applied.max_provider_attempts, observed)
    else
      :ok
    end
  end

  def check_provider_attempt(%Effect.Journal{}, _current_attempts, _applied), do: :ok

  @doc "Counts completed provider calls in an effect journal."
  @spec provider_attempts(Effect.Journal.t()) :: non_neg_integer()
  def provider_attempts(%Effect.Journal{} = journal) do
    journal.results
    |> Map.values()
    |> Enum.filter(&(&1.kind == :llm))
    |> Enum.reduce(0, fn result, total -> total + provider_attempt_count(result) end)
  end

  @doc "Returns the effective capability timeout, including sequence time left."
  @spec capability_timeout(keyword(), pos_integer() | :infinity) :: pos_integer() | :infinity
  def capability_timeout(opts, current) when is_list(opts) do
    applied = Keyword.get(opts, :runtime_limits)
    configured = if is_struct(applied, Applied), do: applied.capability_timeout_ms, else: nil
    sequence_remaining = remaining_sequence_ms(opts, applied)

    [current, configured, sequence_remaining]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(:infinity, &minimum_timeout/2)
  end

  @doc "Checks the sequence deadline before the next turn starts."
  @spec check_sequence_deadline(keyword(), pos_integer()) :: :ok | {:error, Exceeded.t()}
  def check_sequence_deadline(opts, turn_index) when is_list(opts) do
    case {Keyword.get(opts, :runtime_limits), sequence_elapsed_ms(opts)} do
      {%Applied{sequence_timeout_ms: timeout}, elapsed}
      when is_integer(timeout) and elapsed >= timeout ->
        {:error,
         Exceeded.new!(
           kind: :sequence_timeout,
           limit: timeout,
           observed: elapsed,
           turn_index: turn_index
         )}

      _other ->
        :ok
    end
  end

  @doc "Checks cumulative sequence usage after a completed turn."
  @spec check_usage([Sequence.Step.t()], Applied.t(), pos_integer()) :: :ok | {:error, Exceeded.t()}
  def check_usage(steps, %Applied{} = applied, turn_index) when is_list(steps) do
    check_usage(steps, applied, turn_index, :crossed)
  end

  @doc "Checks cumulative sequence capacity before another turn starts."
  @spec check_usage_before_next([Sequence.Step.t()], Applied.t(), pos_integer()) ::
          :ok | {:error, Exceeded.t()}
  def check_usage_before_next(steps, %Applied{} = applied, turn_index) when is_list(steps) do
    check_usage(steps, applied, turn_index, :exhausted)
  end

  defp check_usage(steps, applied, turn_index, mode) do
    usage = aggregate_usage(steps)
    tokens = numeric(usage, :total_tokens)
    cost = numeric(usage, :total_cost)

    cond do
      usage_limit?(tokens, applied.max_total_tokens, mode) ->
        {:error,
         Exceeded.new!(
           kind: :total_tokens,
           limit: applied.max_total_tokens,
           observed: tokens,
           turn_index: turn_index
         )}

      usage_limit?(cost, applied.max_total_cost, mode) ->
        {:error,
         Exceeded.new!(
           kind: :total_cost,
           limit: applied.max_total_cost,
           observed: cost,
           turn_index: turn_index
         )}

      true ->
        :ok
    end
  end

  defp usage_limit?(_observed, nil, _mode), do: false
  defp usage_limit?(observed, limit, :crossed), do: observed > limit
  defp usage_limit?(observed, limit, :exhausted), do: observed >= limit

  @doc "Builds final sequence evidence from completed steps and terminal data."
  @spec evidence(Applied.t(), [Sequence.Step.t()], non_neg_integer(), term()) :: Evidence.t()
  def evidence(%Applied{} = applied, steps, duration_ms, terminal_reason) do
    counts = steps |> Enum.map(& &1.result) |> Jidoka.Loop.counts()

    observed =
      Observed.new!(
        user_turns: counts.user_turns,
        model_steps: counts.model_steps,
        model_turns: counts.model_steps,
        tool_call_groups: counts.tool_call_groups,
        tool_calls: counts.tool_calls,
        provider_attempts: ledger_total(steps, :provider_attempts),
        recovery_steps: ledger_total(steps, :recovery_steps),
        observation_bytes: ledger_total(steps, :observation_bytes),
        result_repairs: ledger_total(steps, :result_repairs),
        sequence_duration_ms: max(duration_ms, 0),
        usage: aggregate_usage(steps),
        environment: applied.environment
      )

    exceeded = exceeded_reason(terminal_reason, observed)

    Evidence.new!(
      status: if(exceeded, do: :exceeded, else: :within),
      applied: applied,
      observed: observed,
      exceeded: exceeded
    )
  end

  @doc "Returns elapsed sequence time from the injected clock."
  @spec sequence_elapsed_ms(keyword()) :: non_neg_integer()
  def sequence_elapsed_ms(opts) when is_list(opts) do
    case Keyword.get(opts, :runtime_sequence_started_at_ms) do
      started when is_integer(started) -> max(clock_ms(opts) - started, 0)
      _started -> 0
    end
  end

  defp resolve_attrs(plan, attrs, opts) do
    attrs =
      if is_list(attrs) and not Keyword.keyword?(attrs) do
        attrs
      else
        Schema.normalize_attrs(attrs)
      end

    normalized = if is_map(attrs), do: Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end), else: attrs

    with true <- is_map(normalized),
         [] <- Map.keys(normalized) -- @keys do
      legacy_capability = positive_or_nil(Keyword.get(opts, :capability_timeout_ms))

      Applied.new(%{
        max_model_turns: minimum(plan.max_model_turns, Map.get(normalized, :max_model_turns)),
        turn_timeout_ms: minimum(plan.timeout_ms, Map.get(normalized, :turn_timeout_ms)),
        capability_timeout_ms: minimum_optional(legacy_capability, Map.get(normalized, :capability_timeout_ms)),
        sequence_timeout_ms: Map.get(normalized, :sequence_timeout_ms),
        max_provider_attempts: Map.get(normalized, :max_provider_attempts),
        max_tool_calls_per_group: Map.get(normalized, :max_tool_calls_per_group),
        max_tool_calls_per_turn: Map.get(normalized, :max_tool_calls_per_turn),
        max_recovery_steps: Map.get(normalized, :max_recovery_steps),
        max_observation_bytes: Map.get(normalized, :max_observation_bytes),
        max_result_repairs: Map.get(normalized, :max_result_repairs),
        max_total_tokens: Map.get(normalized, :max_total_tokens),
        max_total_cost: Map.get(normalized, :max_total_cost),
        environment: Map.get(normalized, :environment, %{})
      })
    else
      false -> {:error, {:invalid_runtime_limits, attrs}}
      unknown when is_list(unknown) -> {:error, {:unknown_runtime_limit_keys, Enum.sort(unknown)}}
    end
  end

  defp tighten_plan_limits(%Applied{} = applied, plan) do
    Applied.new(%{
      applied
      | max_model_turns: min(applied.max_model_turns, plan.max_model_turns),
        turn_timeout_ms: min(applied.turn_timeout_ms, plan.timeout_ms)
    })
  end

  defp add_effect_result(%Ledger{} = ledger, %Effect.Result{kind: :llm} = result) do
    usage = Jidoka.Usage.normalize(Map.get(result.metadata, :usage, Map.get(result.metadata, "usage")))

    %Ledger{
      ledger
      | provider_attempts: ledger.provider_attempts + provider_attempt_count(result),
        total_tokens: ledger.total_tokens + trunc(numeric(usage, :total_tokens)),
        total_cost: ledger.total_cost + numeric(usage, :total_cost)
    }
  end

  defp add_effect_result(%Ledger{} = ledger, %Effect.Result{kind: :operation} = result) do
    %Ledger{ledger | observation_bytes: ledger.observation_bytes + observation_bytes(result.output)}
  end

  defp provider_attempt_count(%Effect.Result{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :model_attempts, Map.get(metadata, "model_attempts")) do
      attempts when is_list(attempts) and attempts != [] -> length(attempts)
      _attempts -> 1
    end
  end

  defp observation_bytes(output) do
    output
    |> Jidoka.Portable.project()
    |> Jason.encode!()
    |> byte_size()
  rescue
    _exception -> :erlang.external_size(output)
  end

  defp check_max(%Turn.State{} = state, kind, observed) do
    case applied(state) do
      %Applied{} = applied ->
        case limit_for(applied, kind) do
          limit when is_number(limit) and observed > limit -> exceeded(kind, limit, observed)
          _limit -> :ok
        end

      nil ->
        :ok
    end
  end

  defp check_capacity(%Turn.State{} = state, kind, observed) do
    case applied(state) do
      %Applied{} = applied ->
        case limit_for(applied, kind) do
          limit when is_number(limit) and observed >= limit -> exceeded(kind, limit, observed)
          _limit -> :ok
        end

      nil ->
        :ok
    end
  end

  defp ledger(%Turn.State{limit_ledger: %Ledger{} = ledger}), do: ledger
  defp ledger(%Turn.State{limit_ledger: attrs}), do: Ledger.new!(attrs)

  defp applied(%Turn.State{limits: %Applied{} = applied}), do: applied
  defp applied(%Turn.State{limits: nil}), do: nil
  defp applied(%Turn.State{limits: attrs}) when is_map(attrs), do: Applied.new!(attrs)

  defp limit_for(applied, :provider_attempts), do: applied.max_provider_attempts
  defp limit_for(applied, :tool_calls_per_group), do: applied.max_tool_calls_per_group
  defp limit_for(applied, :tool_calls_per_turn), do: applied.max_tool_calls_per_turn
  defp limit_for(applied, :recovery_steps), do: applied.max_recovery_steps
  defp limit_for(applied, :observation_bytes), do: applied.max_observation_bytes
  defp limit_for(applied, :total_tokens), do: applied.max_total_tokens
  defp limit_for(applied, :total_cost), do: applied.max_total_cost

  defp exceeded(kind, limit, observed) do
    {:error,
     {:runtime_limit_exceeded,
      Exceeded.new!(
        kind: kind,
        limit: limit,
        observed: observed
      )}}
  end

  defp ledger_total(steps, key) do
    Enum.reduce(steps, 0, fn step, total ->
      case Map.get(step.result, :limit_usage) do
        %Ledger{} = ledger -> total + Map.fetch!(ledger, key)
        ledger when is_map(ledger) -> total + Map.get(ledger, key, Map.get(ledger, Atom.to_string(key), 0))
        _ledger -> total
      end
    end)
  end

  defp remaining_sequence_ms(_opts, %Applied{sequence_timeout_ms: nil}), do: nil

  defp remaining_sequence_ms(opts, %Applied{sequence_timeout_ms: timeout}) do
    max(timeout - sequence_elapsed_ms(opts), 1)
  end

  defp remaining_sequence_ms(_opts, _applied), do: nil

  defp minimum_timeout(:infinity, value), do: value
  defp minimum_timeout(value, :infinity), do: value
  defp minimum_timeout(left, right), do: min(left, right)

  defp minimum(default, nil), do: default
  defp minimum(default, value) when is_integer(value) and value > 0, do: min(default, value)
  defp minimum(_default, value), do: value

  defp minimum_optional(nil, nil), do: nil
  defp minimum_optional(left, nil), do: left
  defp minimum_optional(nil, right), do: right
  defp minimum_optional(left, right) when is_integer(left) and is_integer(right), do: min(left, right)
  defp minimum_optional(_left, right), do: right

  defp positive_or_nil(value) when is_integer(value) and value > 0, do: value
  defp positive_or_nil(_value), do: nil

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    Enum.find(@keys, key, &(Atom.to_string(&1) == key))
  end

  defp normalize_key(key), do: key

  defp aggregate_usage(steps) do
    Enum.reduce(steps, %{}, fn step, acc ->
      Enum.reduce(step.result.usage, acc, &merge_numeric_usage/2)
    end)
  end

  defp merge_numeric_usage({key, value}, usage) when is_number(value),
    do: Map.update(usage, key, value, &(&1 + value))

  defp merge_numeric_usage({_key, _value}, usage), do: usage

  defp numeric(map, key) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key), 0)) do
      value when is_number(value) -> value
      _value -> 0
    end
  end

  defp exceeded_reason(%Exceeded{} = exceeded, _observed), do: exceeded

  defp exceeded_reason({:runtime_limit_exceeded, %Exceeded{} = exceeded}, _observed),
    do: exceeded

  defp exceeded_reason({:runtime_limit_exceeded, %{} = attrs}, _observed) do
    case Exceeded.new(attrs) do
      {:ok, exceeded} -> exceeded
      {:error, _reason} -> nil
    end
  end

  defp exceeded_reason({:max_model_turns_exceeded, max}, observed) do
    Exceeded.new!(kind: :model_turns, limit: max, observed: max, turn_index: max(observed.model_turns, 1))
  end

  defp exceeded_reason({:turn_timeout_exceeded, timeout, elapsed}, observed) do
    Exceeded.new!(
      kind: :turn_timeout,
      limit: timeout,
      observed: elapsed,
      turn_index: max(observed.model_turns, 1)
    )
  end

  defp exceeded_reason({:capability_timeout, effect_kind, timeout}, observed) do
    Exceeded.new!(
      kind: :capability_timeout,
      limit: timeout,
      observed: timeout,
      turn_index: max(observed.model_turns, 1),
      effect_kind: effect_kind
    )
  end

  defp exceeded_reason(
         %{details: %{reason: :capability_timeout, effect_kind: effect_kind, timeout_ms: timeout}},
         observed
       ) do
    exceeded_reason({:capability_timeout, effect_kind, timeout}, observed)
  end

  defp exceeded_reason(%{details: %{limit: %Exceeded{} = exceeded}}, _observed),
    do: exceeded

  defp exceeded_reason(%{details: %{limit: %{} = attrs}}, _observed) do
    case Exceeded.new(attrs) do
      {:ok, exceeded} -> exceeded
      {:error, _reason} -> nil
    end
  end

  defp exceeded_reason(_reason, _observed), do: nil

  defp clock_ms(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _clock -> System.monotonic_time(:millisecond)
    end
  end
end
