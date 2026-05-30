defmodule Jidoka.Agent.Spec.Controls.Operation do
  @moduledoc """
  Policy control attached to model-callable operations.
  """

  alias Jidoka.Schema

  @valid_kinds [:action, :operation, :tool, :workflow, :subagent, :handoff]

  @schema Zoi.struct(
            __MODULE__,
            %{
              control: Zoi.atom(),
              match: Zoi.map() |> Zoi.default(%{}),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec valid_kinds() :: [atom()]
  def valid_kinds, do: @valid_kinds

  @doc "Returns true when this operation control applies to an operation name/kind."
  @spec matches?(t(), String.t(), atom()) :: boolean()
  def matches?(%__MODULE__{match: match}, operation_name, operation_kind) do
    Enum.all?(match, fn
      {:kind, kind} -> kind == operation_kind
      {:name, name} -> name == operation_name
    end)
  end

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, match} <- normalize_match(Schema.get_key(attrs, :match, %{})),
         {:ok, %__MODULE__{} = operation} <-
           Schema.parse(@schema, Map.put(attrs, :match, match)),
         :ok <- Jidoka.Control.validate_module(operation.control) do
      {:ok, operation}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, operation} -> operation
      {:error, reason} -> raise ArgumentError, "invalid operation control: #{inspect(reason)}"
    end
  end

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = operation), do: new(operation)
  def from_input(input), do: new(input)

  defp normalize_match(nil), do: {:ok, %{}}

  defp normalize_match(match) when is_list(match) do
    match
    |> Map.new()
    |> normalize_match()
  rescue
    exception -> {:error, {:invalid_operation_control_match, exception}}
  end

  defp normalize_match(%{} = match) do
    allowed_keys = [:kind, "kind", :name, "name"]

    case Enum.reject(Map.keys(match), &(&1 in allowed_keys)) do
      [] ->
        with {:ok, kind_match} <- normalize_kind(Map.get(match, :kind, Map.get(match, "kind"))),
             {:ok, name_match} <- normalize_name(Map.get(match, :name, Map.get(match, "name"))) do
          {:ok,
           %{}
           |> maybe_put(:kind, kind_match)
           |> maybe_put(:name, name_match)}
        end

      unknown ->
        {:error, {:unknown_operation_control_match_keys, unknown}}
    end
  end

  defp normalize_match(other), do: {:error, {:invalid_operation_control_match, other}}

  defp normalize_kind(nil), do: {:ok, nil}
  defp normalize_kind(kind) when kind in @valid_kinds, do: {:ok, kind}

  defp normalize_kind(kind) when is_binary(kind) do
    kind = kind |> String.trim() |> String.downcase()

    case Enum.find(@valid_kinds, &(Atom.to_string(&1) == kind)) do
      nil -> {:error, {:invalid_operation_control_kind, kind}}
      kind -> {:ok, kind}
    end
  end

  defp normalize_kind(kind), do: {:error, {:invalid_operation_control_kind, kind}}

  defp normalize_name(nil), do: {:ok, nil}

  defp normalize_name(name) when is_atom(name) and not is_nil(name) do
    normalize_name(Atom.to_string(name))
  end

  defp normalize_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, {:invalid_operation_control_name, name}}
      name -> {:ok, name}
    end
  end

  defp normalize_name(name), do: {:error, {:invalid_operation_control_name, name}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule Jidoka.Agent.Spec.Controls.Input do
  @moduledoc """
  Control attached to the input boundary.
  """

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              control: Zoi.atom(),
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
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, %__MODULE__{} = input} <- Schema.parse(@schema, attrs),
         :ok <- Jidoka.Control.validate_module(input.control) do
      {:ok, input}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, input} -> input
      {:error, reason} -> raise ArgumentError, "invalid input control: #{inspect(reason)}"
    end
  end

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = input), do: new(input)
  def from_input(input), do: new(input)
end

defmodule Jidoka.Agent.Spec.Controls.Result do
  @moduledoc """
  Control attached to the final output boundary.
  """

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              control: Zoi.atom(),
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
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, %__MODULE__{} = result} <- Schema.parse(@schema, attrs),
         :ok <- Jidoka.Control.validate_module(result.control) do
      {:ok, result}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, result} -> result
      {:error, reason} -> raise ArgumentError, "invalid output control: #{inspect(reason)}"
    end
  end

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = result), do: new(result)
  def from_input(input), do: new(input)
end

defmodule Jidoka.Agent.Spec.Controls do
  @moduledoc """
  Policy controls attached to a Jidoka agent definition.
  """

  alias Jidoka.Agent.Spec.Controls.Input
  alias Jidoka.Agent.Spec.Controls.Operation
  alias Jidoka.Agent.Spec.Controls.Result
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              max_turns: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              timeout_ms: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              inputs: Zoi.array(Zoi.lazy({Input, :schema, []})) |> Zoi.default([]),
              operations: Zoi.array(Zoi.lazy({Operation, :schema, []})) |> Zoi.default([]),
              results: Zoi.array(Zoi.lazy({Result, :schema, []})) |> Zoi.default([]),
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
         {:ok, results} <- normalize_results(output_entries(attrs)),
         :ok <- validate_unique_boundary_controls(inputs, Input, :duplicate_input_control),
         :ok <- validate_unique_operations(operations),
         :ok <- validate_unique_boundary_controls(results, Result, :duplicate_output_control) do
      attrs =
        attrs
        |> Map.delete(:timeout)
        |> Map.delete("timeout")
        |> Map.delete(:input)
        |> Map.delete("input")
        |> Map.delete(:operation)
        |> Map.delete("operation")
        |> Map.delete(:output)
        |> Map.delete("output")
        |> Map.delete(:outputs)
        |> Map.delete("outputs")
        |> Map.delete(:result)
        |> Map.delete("result")
        |> Map.delete(:results)
        |> Map.delete("results")
        |> Map.put(:max_turns, max_turns)
        |> Map.put(:timeout_ms, timeout_ms)
        |> Map.put(:inputs, inputs)
        |> Map.put(:operations, operations)
        |> Map.put(:results, results)

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

  defp output_entries(attrs) do
    case Schema.fetch_key(attrs, :outputs) do
      {:ok, value} ->
        value

      :error ->
        case Schema.fetch_key(attrs, :output) do
          {:ok, value} -> value
          :error -> control_entries(attrs, :results, :result)
        end
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

  defp normalize_results(results),
    do: normalize_boundary_controls(results, Result, :invalid_output_controls)

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
end
