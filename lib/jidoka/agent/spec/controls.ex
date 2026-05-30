defmodule Jidoka.Agent.Spec.Controls do
  @moduledoc """
  Policy controls attached to a Jidoka agent definition.
  """

  alias Jidoka.Agent.Spec.Controls.Input
  alias Jidoka.Agent.Spec.Controls.Operation
  alias Jidoka.Agent.Spec.Controls.Output
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              max_turns: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              timeout_ms: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              inputs: Zoi.array(Zoi.lazy({Input, :schema, []})) |> Zoi.default([]),
              operations: Zoi.array(Zoi.lazy({Operation, :schema, []})) |> Zoi.default([]),
              outputs: Zoi.array(Zoi.lazy({Output, :schema, []})) |> Zoi.default([]),
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
  def new(attrs \\ []) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, max_turns} <- normalize_positive_integer(Schema.get_key(attrs, :max_turns)),
         {:ok, timeout_ms} <- normalize_positive_integer(timeout_value(attrs)),
         {:ok, inputs} <- normalize_inputs(control_entries(attrs, :inputs, :input)),
         {:ok, operations} <-
           normalize_operations(control_entries(attrs, :operations, :operation)),
         {:ok, outputs} <- normalize_outputs(control_entries(attrs, :outputs, :output)),
         :ok <- validate_unique_boundary_controls(inputs, Input, :duplicate_input_control),
         :ok <- validate_unique_operations(operations),
         :ok <- validate_unique_boundary_controls(outputs, Output, :duplicate_output_control) do
      attrs =
        attrs
        |> drop_input_aliases()
        |> Map.put(:max_turns, max_turns)
        |> Map.put(:timeout_ms, timeout_ms)
        |> Map.put(:inputs, inputs)
        |> Map.put(:operations, operations)
        |> Map.put(:outputs, outputs)

      Schema.parse(@schema, attrs)
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ []) do
    case new(attrs) do
      {:ok, controls} -> controls
      {:error, reason} -> raise ArgumentError, "invalid controls: #{inspect(reason)}"
    end
  end

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = controls), do: new(controls)
  def from_input(input), do: new(input)

  defp timeout_value(attrs) do
    Schema.get_key(attrs, :timeout_ms) ||
      Schema.get_key(attrs, :timeout)
  end

  defp control_entries(attrs, plural_key, singular_key) do
    case Schema.fetch_key(attrs, plural_key) do
      {:ok, value} -> value
      :error -> Schema.get_key(attrs, singular_key, [])
    end
  end

  defp normalize_positive_integer(nil), do: {:ok, nil}
  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, {:invalid_control_positive_integer, value}}
    end
  end

  defp normalize_positive_integer(value), do: {:error, {:invalid_control_positive_integer, value}}

  defp normalize_inputs(inputs),
    do: normalize_boundary_controls(inputs, Input, :invalid_input_controls)

  defp normalize_outputs(outputs),
    do: normalize_boundary_controls(outputs, Output, :invalid_output_controls)

  defp normalize_boundary_controls(controls, module, _error_reason) when is_list(controls) do
    controls
    |> Enum.reduce_while({:ok, []}, fn control, {:ok, controls} ->
      case module.from_input(control) do
        {:ok, control} -> {:cont, {:ok, [control | controls]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, controls} -> {:ok, Enum.reverse(controls)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_boundary_controls(%{} = control, module, error_reason),
    do: normalize_boundary_controls([control], module, error_reason)

  defp normalize_boundary_controls(controls, _module, error_reason),
    do: {:error, {error_reason, controls}}

  defp normalize_operations(operations) when is_list(operations) do
    operations
    |> Enum.reduce_while({:ok, []}, fn operation, {:ok, operations} ->
      case Operation.from_input(operation) do
        {:ok, operation} -> {:cont, {:ok, [operation | operations]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_operations(%{} = operation), do: normalize_operations([operation])

  defp normalize_operations(operations), do: {:error, {:invalid_operation_controls, operations}}

  defp validate_unique_boundary_controls(controls, module, reason) do
    controls
    |> Enum.reduce_while(MapSet.new(), fn %{__struct__: ^module, control: control}, seen ->
      key = control

      if MapSet.member?(seen, key) do
        {:halt, {:error, {reason, control}}}
      else
        {:cont, MapSet.put(seen, key)}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_unique_operations(operations) do
    operations
    |> Enum.reduce_while(MapSet.new(), fn %Operation{} = operation, seen ->
      key = {operation.control, operation.match}

      if MapSet.member?(seen, key) do
        {:halt, {:error, {:duplicate_operation_control, operation.control, operation.match}}}
      else
        {:cont, MapSet.put(seen, key)}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop_input_aliases(attrs) do
    attrs
    |> Map.delete(:timeout)
    |> Map.delete("timeout")
    |> Map.delete(:input)
    |> Map.delete("input")
    |> Map.delete(:operation)
    |> Map.delete("operation")
    |> Map.delete(:output)
    |> Map.delete("output")
  end
end
