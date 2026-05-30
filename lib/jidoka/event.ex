defmodule Jidoka.Event do
  @moduledoc """
  Core event emitted by Jidoka turn transitions.

  Events are neutral harness data. Extensions may project or consume them, but
  core workflow/state modules should not depend on concrete extension modules.
  """

  alias Jidoka.Schema

  @event_defaults %{
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
    control_failed: %{category: :control, phase: :control, status: :failed},
    operation_observed: %{
      category: :operation,
      phase: :apply_operation_results,
      status: :completed
    },
    turn_finished: %{category: :workflow, phase: :finish, status: :completed}
  }
  @categories [:workflow, :effect, :runtime, :operation, :control]
  @phases [
    :control,
    :assemble_prompt,
    :plan_model_effect,
    :interpret_effect,
    :apply_operation_results,
    :finish
  ]
  @statuses [:planned, :started, :replayed, :completed, :failed]

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

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the core event names currently emitted by Jidoka."
  @spec events() :: [atom()]
  def events, do: Map.keys(@event_defaults)

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "event")

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
end
