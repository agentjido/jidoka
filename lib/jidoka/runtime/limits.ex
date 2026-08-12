defmodule Jidoka.Runtime.Limits.Applied do
  @moduledoc "Portable limits that the Jidoka runtime applies to one turn or sequence."

  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.integer() |> Zoi.positive() |> Zoi.default(1),
              max_model_turns: Zoi.integer() |> Zoi.positive(),
              turn_timeout_ms: Zoi.integer() |> Zoi.positive(),
              capability_timeout_ms: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              sequence_timeout_ms: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              max_total_tokens: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              max_total_cost: Zoi.number() |> Zoi.gt(0) |> Zoi.nullish(),
              environment:
                Zoi.map()
                |> Zoi.default(%{})
                |> Zoi.refine({Contract, :validate_safe_map, []})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the applied-limit schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds applied limits."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds applied limits or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "applied runtime limits")
end

defmodule Jidoka.Runtime.Limits.Observed do
  @moduledoc "Portable usage facts observed while Jidoka applies runtime limits."

  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              model_turns: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              sequence_duration_ms: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              usage: Zoi.map() |> Zoi.default(%{}),
              environment:
                Zoi.map()
                |> Zoi.default(%{})
                |> Zoi.refine({Contract, :validate_safe_map, []})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the observed-limit schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds observed limit facts."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds observed limit facts or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "observed runtime limits")
end

defmodule Jidoka.Runtime.Limits.Exceeded do
  @moduledoc "Portable evidence for one runtime limit that stopped work."

  alias Jidoka.Schema

  @kinds [
    :model_turns,
    :turn_timeout,
    :capability_timeout,
    :sequence_timeout,
    :total_tokens,
    :total_cost,
    :environment
  ]

  @schema Zoi.struct(
            __MODULE__,
            %{
              kind: Schema.atom_enum(@kinds),
              limit: Zoi.number(),
              observed: Zoi.number(),
              turn_index: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              effect_kind: Zoi.atom() |> Zoi.nullish()
            },
            coerce: true
          )

  @type kind ::
          :model_turns
          | :turn_timeout
          | :capability_timeout
          | :sequence_timeout
          | :total_tokens
          | :total_cost
          | :environment
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the supported limit kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Returns the limit-exceeded schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds limit-exceeded evidence."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds limit-exceeded evidence or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "runtime limit exceeded")
end

defmodule Jidoka.Runtime.Limits.Evidence do
  @moduledoc "Portable applied, observed, and exceeded runtime-limit evidence."

  alias Jidoka.Runtime.Limits
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.integer() |> Zoi.positive() |> Zoi.default(1),
              status: Schema.atom_enum([:within, :exceeded]),
              applied: Zoi.lazy({Limits.Applied, :schema, []}),
              observed: Zoi.lazy({Limits.Observed, :schema, []}),
              exceeded: Zoi.lazy({Limits.Exceeded, :schema, []}) |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the runtime-limit evidence schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds runtime-limit evidence."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds runtime-limit evidence or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "runtime limit evidence")
end

defmodule Jidoka.Runtime.Limits do
  @moduledoc """
  Resolves and evaluates provider-neutral runtime limits.

  Callers can use `:runtime_limits` to reduce a turn plan. Jidoka keeps the
  plan limits as hard upper bounds. A sequence result contains portable
  applied, observed, and exceeded evidence.
  """

  alias Jidoka.Runtime.Limits.{Applied, Evidence, Exceeded, Observed}
  alias Jidoka.Schema
  alias Jidoka.Session.Sequence
  alias Jidoka.Turn

  @keys [
    :max_model_turns,
    :turn_timeout_ms,
    :capability_timeout_ms,
    :sequence_timeout_ms,
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
    usage = aggregate_usage(steps)

    cond do
      is_integer(applied.max_total_tokens) and numeric(usage, :total_tokens) > applied.max_total_tokens ->
        {:error,
         Exceeded.new!(
           kind: :total_tokens,
           limit: applied.max_total_tokens,
           observed: numeric(usage, :total_tokens),
           turn_index: turn_index
         )}

      is_number(applied.max_total_cost) and numeric(usage, :total_cost) > applied.max_total_cost ->
        {:error,
         Exceeded.new!(
           kind: :total_cost,
           limit: applied.max_total_cost,
           observed: numeric(usage, :total_cost),
           turn_index: turn_index
         )}

      true ->
        :ok
    end
  end

  @doc "Builds final sequence evidence from completed steps and terminal data."
  @spec evidence(Applied.t(), [Sequence.Step.t()], non_neg_integer(), term()) :: Evidence.t()
  def evidence(%Applied{} = applied, steps, duration_ms, terminal_reason) do
    observed =
      Observed.new!(
        model_turns: Enum.reduce(steps, 0, &(&2 + model_turn_count(&1.result))),
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
    attrs = Schema.normalize_attrs(attrs)
    normalized = if is_map(attrs), do: Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end), else: attrs

    with true <- is_map(normalized),
         [] <- Map.keys(normalized) -- @keys do
      legacy_capability = positive_or_nil(Keyword.get(opts, :capability_timeout_ms))

      Applied.new(%{
        max_model_turns: minimum(plan.max_model_turns, Map.get(normalized, :max_model_turns)),
        turn_timeout_ms: minimum(plan.timeout_ms, Map.get(normalized, :turn_timeout_ms)),
        capability_timeout_ms: minimum_optional(legacy_capability, Map.get(normalized, :capability_timeout_ms)),
        sequence_timeout_ms: Map.get(normalized, :sequence_timeout_ms),
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

  defp model_turn_count(%Turn.Result{journal: journal}) do
    Enum.count(journal.results, fn {_id, result} -> result.kind == :llm end)
  end

  defp numeric(map, key) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key), 0)) do
      value when is_number(value) -> value
      _value -> 0
    end
  end

  defp exceeded_reason(%Exceeded{} = exceeded, _observed), do: exceeded

  defp exceeded_reason({:runtime_limit_exceeded, %Exceeded{} = exceeded}, _observed),
    do: exceeded

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

  defp exceeded_reason(_reason, _observed), do: nil

  defp clock_ms(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _clock -> System.monotonic_time(:millisecond)
    end
  end
end
