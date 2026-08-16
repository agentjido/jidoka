defmodule Jidoka.Workflow.Step do
  @moduledoc "Data contract for one deterministic workflow step."

  alias Jidoka.Schema
  alias Jidoka.Workflow.RetryPolicy

  @kinds [:function, :action, :agent, :gate, :map, :reduce, :loop]
  @map_targets [:function, :action]

  @base_schema Zoi.struct(
                 __MODULE__,
                 %{
                   name: Zoi.atom(),
                   kind: Schema.atom_enum(@kinds),
                   target: Zoi.any() |> Zoi.nullish(),
                   target_kind: Schema.atom_enum(@map_targets) |> Zoi.nullish(),
                   input: Zoi.any() |> Zoi.default(%{}),
                   prompt: Zoi.any() |> Zoi.nullish(),
                   context: Zoi.any() |> Zoi.default(%{}),
                   condition: Zoi.any() |> Zoi.nullish(),
                   condition_when: Zoi.any() |> Zoi.nullish(),
                   condition_unless: Zoi.any() |> Zoi.nullish(),
                   over: Zoi.any() |> Zoi.nullish(),
                   initial: Zoi.any() |> Zoi.nullish(),
                   using: Zoi.any() |> Zoi.nullish(),
                   max_concurrency: Zoi.integer() |> Zoi.gt(0) |> Zoi.nullish(),
                   max_iterations: Zoi.integer() |> Zoi.gt(0) |> Zoi.nullish(),
                   after: Zoi.array(Zoi.atom()) |> Zoi.default([]),
                   retry: Zoi.lazy({RetryPolicy, :schema, []}) |> Zoi.nullish(),
                   metadata: Zoi.map() |> Zoi.default(%{})
                 },
                 coerce: true
               )

  @schema Zoi.refine(@base_schema, {__MODULE__, :validate_kind_fields, []})

  @kind_fields %{
    function: %{required: [:target], allowed: [:target, :input, :condition_when, :condition_unless, :retry]},
    action: %{required: [:target], allowed: [:target, :input, :condition_when, :condition_unless, :retry]},
    agent: %{
      required: [:target, :prompt],
      allowed: [:target, :prompt, :context, :condition_when, :condition_unless, :retry]
    },
    gate: %{required: [:condition], allowed: [:condition]},
    map: %{
      required: [:target, :target_kind, :over],
      allowed: [:target, :target_kind, :input, :over, :max_concurrency, :condition_when, :condition_unless, :retry]
    },
    reduce: %{
      required: [:target, :over],
      allowed: [:target, :input, :over, :condition_when, :condition_unless, :retry]
    },
    loop: %{
      required: [:target, :initial, :max_iterations],
      allowed: [:target, :input, :initial, :max_iterations, :condition_when, :condition_unless, :retry]
    }
  }

  @kind_specific_fields [
    :target,
    :target_kind,
    :input,
    :prompt,
    :context,
    :condition,
    :condition_when,
    :condition_unless,
    :over,
    :initial,
    :using,
    :max_concurrency,
    :max_iterations,
    :retry
  ]

  @type t :: unquote(Zoi.type_spec(@base_schema))
  @enforce_keys Zoi.Struct.enforce_keys(@base_schema)
  defstruct Zoi.Struct.struct_fields(@base_schema)

  @doc "Returns the Zoi schema for workflow steps."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the supported deterministic workflow step kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "Returns the supported map target kinds."
  @spec map_targets() :: [atom()]
  def map_targets, do: @map_targets

  @doc "Parses workflow step attributes into a validated step."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, %__MODULE__{} = step} <- Schema.parse(@base_schema, attrs),
         :ok <- validate_step(step) do
      {:ok, step}
    end
  end

  @doc "Parses workflow step attributes into a validated step or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, step} -> step
      {:error, reason} -> raise ArgumentError, "invalid workflow step: #{inspect(reason)}"
    end
  end

  @doc "Normalizes a valid existing workflow step or step attributes."
  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = step), do: new(step)
  def from_input(attrs), do: new(attrs)

  @doc false
  @spec validate_kind_fields(t(), keyword()) :: :ok | {:error, String.t()}
  def validate_kind_fields(%__MODULE__{} = step, _opts) do
    case validate_step(step) do
      :ok -> :ok
      {:error, reason} -> {:error, "invalid workflow step kind fields: #{inspect(reason)}"}
    end
  end

  defp validate_step(%__MODULE__{kind: kind} = step) do
    %{required: required, allowed: allowed} = Map.fetch!(@kind_fields, kind)
    missing = Enum.reject(required, &present?(step, &1))
    invalid = @kind_specific_fields |> Enum.reject(&(&1 in allowed)) |> Enum.filter(&present?(step, &1))

    cond do
      missing != [] -> {:error, {:missing_workflow_step_fields, kind, missing}}
      invalid != [] -> {:error, {:invalid_workflow_step_fields, kind, invalid}}
      true -> :ok
    end
  end

  defp present?(step, field) when field in [:input, :context],
    do: Map.fetch!(step, field) not in [nil, %{}]

  defp present?(step, field), do: not is_nil(Map.fetch!(step, field))
end
