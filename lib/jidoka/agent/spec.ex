defmodule Jidoka.Agent.Spec do
  @moduledoc """
  Canonical immutable definition of a Jidoka agent.
  """

  alias Jidoka.Config
  alias Jidoka.Agent.Spec.{Controls, Generation, Memory, Operation, Result}
  alias Jidoka.Schema

  @default_controls Controls.new!()

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Schema.non_empty_string(),
              instructions: Schema.non_empty_string(),
              model: Zoi.lazy({LLMDB.Model, :schema, []}),
              generation: Zoi.lazy({Generation, :schema, []}),
              context_schema: Zoi.any() |> Zoi.nullish(),
              result: Zoi.lazy({Result, :schema, []}) |> Zoi.nullish(),
              memory: Zoi.lazy({Memory, :schema, []}) |> Zoi.nullish(),
              operations: Zoi.array(Zoi.lazy({Operation, :schema, []})) |> Zoi.default([]),
              controls: Zoi.lazy({Controls, :schema, []}) |> Zoi.default(@default_controls),
              runtime_defaults: Zoi.map() |> Zoi.default(%{}),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_model_input(attrs),
         {:ok, attrs} <- normalize_generation_input(attrs),
         {:ok, attrs} <- normalize_result_input(attrs),
         {:ok, attrs} <- normalize_memory_input(attrs),
         {:ok, attrs} <- normalize_controls_input(attrs) do
      Schema.parse(@schema, attrs)
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, "invalid agent spec: #{inspect(reason)}"
    end
  end

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = spec), do: new(spec)
  def from_input(input), do: new(input)

  @spec validate_context(t(), map()) :: :ok | {:error, term()}
  def validate_context(%__MODULE__{context_schema: nil}, context) when is_map(context), do: :ok

  def validate_context(%__MODULE__{context_schema: schema}, context) when is_map(context) do
    case Zoi.parse(schema, context) do
      {:ok, _validated_context} -> :ok
      {:error, reason} -> {:error, {:invalid_context, reason}}
    end
  rescue
    exception -> {:error, {:invalid_context_schema, exception}}
  end

  @spec validate_result(t(), term()) :: {:ok, term()} | {:error, term()}
  def validate_result(%__MODULE__{result: nil}, value), do: {:ok, value}

  def validate_result(%__MODULE__{result: %Result{} = result}, value) do
    case Result.validate(result, value) do
      {:ok, validated} -> {:ok, validated}
      {:error, reason} -> {:error, {:invalid_result, reason}}
    end
  end

  @spec validate_operation_policies(t()) :: :ok | {:error, term()}
  def validate_operation_policies(%__MODULE__{operations: operations} = spec) do
    Enum.reduce_while(operations, :ok, fn %Operation{} = operation, :ok ->
      case validate_operation_policy(spec, operation) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec validate_operation_policy(t(), Operation.t()) :: :ok | {:error, term()}
  def validate_operation_policy(%__MODULE__{} = spec, %Operation{} = operation) do
    if Operation.requires_control?(operation) and not operation_controlled?(spec, operation) do
      {:error, {:unsafe_once_requires_control, operation.name, Operation.kind(operation)}}
    else
      :ok
    end
  end

  defp normalize_model_input(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    case raw_model(attrs) do
      nil ->
        {:ok, put_model(attrs, Config.default_model())}

      model ->
        with {:ok, model} <- Config.normalize_model_spec(model) do
          {:ok, put_model(attrs, model)}
        end
    end
  end

  defp normalize_generation_input(attrs) do
    case raw_generation(attrs) do
      nil ->
        {:ok, put_generation(attrs, Config.default_generation())}

      generation ->
        with {:ok, generation} <- Config.normalize_generation(generation) do
          {:ok, put_generation(attrs, generation)}
        end
    end
  end

  defp normalize_controls_input(attrs) do
    case raw_controls(attrs) do
      nil ->
        {:ok, put_controls(attrs, Controls.new!())}

      controls ->
        with {:ok, controls} <- Controls.from_input(controls) do
          {:ok, put_controls(attrs, controls)}
        end
    end
  end

  defp normalize_result_input(attrs) do
    case raw_result(attrs) do
      nil ->
        {:ok, put_result(attrs, nil)}

      result ->
        with {:ok, result} <- Result.from_input(result) do
          {:ok, put_result(attrs, result)}
        end
    end
  end

  defp normalize_memory_input(attrs) do
    case raw_memory(attrs) do
      nil ->
        {:ok, put_memory(attrs, nil)}

      memory ->
        with {:ok, memory} <- Memory.from_input(memory) do
          {:ok, put_memory(attrs, memory)}
        end
    end
  end

  defp raw_model(attrs) when is_map(attrs) do
    Map.get(attrs, :model, Map.get(attrs, "model"))
  end

  defp raw_generation(attrs) when is_map(attrs) do
    Map.get(attrs, :generation, Map.get(attrs, "generation"))
  end

  defp raw_controls(attrs) when is_map(attrs) do
    Map.get(attrs, :controls, Map.get(attrs, "controls"))
  end

  defp raw_result(attrs) when is_map(attrs) do
    Map.get(attrs, :result, Map.get(attrs, "result"))
  end

  defp raw_memory(attrs) when is_map(attrs) do
    Map.get(attrs, :memory, Map.get(attrs, "memory"))
  end

  defp put_model(attrs, model) when is_map(attrs) do
    attrs
    |> Map.delete("model")
    |> Map.put(:model, model)
  end

  defp put_generation(attrs, generation) when is_map(attrs) do
    attrs
    |> Map.delete("generation")
    |> Map.put(:generation, generation)
  end

  defp put_controls(attrs, controls) when is_map(attrs) do
    attrs
    |> Map.delete("controls")
    |> Map.put(:controls, controls)
  end

  defp put_result(attrs, result) when is_map(attrs) do
    attrs
    |> Map.delete("result")
    |> Map.put(:result, result)
  end

  defp put_memory(attrs, memory) when is_map(attrs) do
    attrs
    |> Map.delete("memory")
    |> Map.put(:memory, memory)
  end

  defp operation_controlled?(
         %__MODULE__{controls: %Controls{} = controls},
         %Operation{} = operation
       ) do
    Enum.any?(
      controls.operations,
      &Controls.Operation.matches?(&1, operation)
    )
  end

  defp operation_controlled?(_spec, _operation), do: false
end
