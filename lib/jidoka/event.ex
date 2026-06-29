defmodule Jidoka.Event do
  @moduledoc """
  Core event emitted by Jidoka turn transitions.

  Events are neutral harness data. Runtime, trace, streaming, and UI modules
  may project or consume them, but workflow/state modules should only emit the
  event data itself.
  """

  alias Jidoka.Schema

  @event_defaults %{
    turn_started: %{category: :workflow, phase: :start, status: :started},
    prompt_assembled: %{category: :workflow, phase: :assemble_prompt, status: :completed},
    effect_planned: %{category: :effect, status: :planned},
    effect_started: %{category: :effect, phase: :interpret_effect, status: :started},
    effect_replayed: %{category: :effect, phase: :interpret_effect, status: :replayed},
    effect_completed: %{category: :effect, phase: :interpret_effect, status: :completed},
    effect_failed: %{category: :effect, phase: :interpret_effect, status: :failed},
    capability_call_started: %{category: :runtime, phase: :interpret_effect, status: :started},
    capability_call_completed: %{
      category: :runtime,
      phase: :interpret_effect,
      status: :completed
    },
    capability_call_failed: %{category: :runtime, phase: :interpret_effect, status: :failed},
    control_allowed: %{category: :control, phase: :control, status: :completed},
    control_blocked: %{category: :control, phase: :control, status: :failed},
    control_interrupted: %{category: :control, phase: :control, status: :pending},
    control_failed: %{category: :control, phase: :control, status: :failed},
    approval_requested: %{category: :approval, phase: :review, status: :pending},
    approval_responded: %{category: :approval, phase: :review, status: :completed},
    approval_applied: %{category: :approval, phase: :review, status: :completed},
    result_validated: %{category: :result, phase: :validate_result, status: :completed},
    result_repair_requested: %{category: :result, phase: :validate_result, status: :planned},
    memory_recalled: %{category: :memory, phase: :memory, status: :completed},
    memory_written: %{category: :memory, phase: :memory, status: :completed},
    operation_observed: %{
      category: :operation,
      phase: :apply_operation_results,
      status: :completed
    },
    llm_delta: %{category: :runtime, phase: :interpret_effect, status: :started},
    turn_finished: %{category: :workflow, phase: :finish, status: :completed},
    turn_hibernated: %{category: :workflow, phase: :finish, status: :pending},
    turn_failed: %{category: :workflow, phase: :finish, status: :failed}
  }
  @categories [
    :workflow,
    :effect,
    :runtime,
    :operation,
    :control,
    :approval,
    :result,
    :memory
  ]
  @phases [
    :start,
    :control,
    :review,
    :memory,
    :assemble_prompt,
    :plan_model_effect,
    :interpret_effect,
    :validate_result,
    :apply_operation_results,
    :finish
  ]
  @statuses [:planned, :pending, :started, :replayed, :completed, :failed]

  @schema Zoi.struct(
            __MODULE__,
            %{
              seq: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              event: Schema.atom_enum(Map.keys(@event_defaults)),
              category: Schema.atom_enum(@categories) |> Zoi.default(:workflow),
              phase: Schema.atom_enum(@phases) |> Zoi.nullish(),
              status: Schema.atom_enum(@statuses) |> Zoi.nullish(),
              agent_id: Schema.non_empty_string() |> Zoi.nullish(),
              request_id: Schema.non_empty_string() |> Zoi.nullish(),
              loop_index: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish(),
              effect_id: Schema.non_empty_string() |> Zoi.nullish(),
              effect_kind: Schema.atom_enum([:llm, :operation]) |> Zoi.nullish(),
              operation: Schema.non_empty_string() |> Zoi.nullish(),
              data: Zoi.map() |> Zoi.default(%{}),
              error: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type data :: %{optional(atom()) => term()}
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the core event names currently emitted by Jidoka."
  @spec events() :: [atom()]
  def events, do: Map.keys(@event_defaults)

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, %__MODULE__{} = event} <- Schema.parse(@schema, attrs),
         :ok <- validate_data_keys(event) do
      {:ok, event}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, event} -> event
      {:error, reason} -> raise ArgumentError, "invalid event: #{inspect(reason)}"
    end
  end

  @doc "Builds a core event with defaults for known Jidoka event names."
  @spec build(atom(), list(), keyword() | map()) :: t()
  def build(event, existing_events \\ [], attrs \\ [])
      when is_atom(event) and is_list(existing_events) do
    attrs = Schema.normalize_attrs(attrs)

    @event_defaults
    |> Map.get(event, %{category: :workflow})
    |> Map.merge(attrs)
    |> Map.put(:event, event)
    |> Map.put_new(:seq, length(existing_events))
    |> Map.put_new(:data, %{})
    |> new!()
  end

  @doc "Returns true when an event represents a cancelled turn."
  @spec cancelled?(t()) :: boolean()
  def cancelled?(%__MODULE__{event: :turn_failed} = event) do
    failure_reason(event) == :cancelled
  end

  def cancelled?(%__MODULE__{}), do: false

  @doc "Returns the failure reason carried by a turn-failed event."
  @spec failure_reason(t()) :: term()
  def failure_reason(%__MODULE__{event: :turn_failed, data: %{reason: reason}}), do: reason
  def failure_reason(%__MODULE__{event: :turn_failed, error: error}), do: error
  def failure_reason(%__MODULE__{}), do: nil

  @doc "Projects an event into a compact map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    event
    |> Map.from_struct()
    |> Enum.reject(fn
      {_key, nil} -> true
      {:data, data} when data == %{} -> true
      {_key, _value} -> false
    end)
    |> Map.new()
  end

  defp validate_data_keys(%__MODULE__{data: data}) when is_map(data) do
    case Enum.find(Map.keys(data), &(not is_atom(&1))) do
      nil -> :ok
      key -> {:error, {:invalid_event_data_key, key}}
    end
  end
end
