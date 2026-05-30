defmodule Jidoka.Operation.Source.Local do
  @moduledoc """
  Local operation source backed by Elixir functions.

  This source is primarily for deterministic tests, examples, and lightweight
  in-process operations. It is deliberately normalized through the same
  operation contract as Jido actions.
  """

  @behaviour Jidoka.Operation.Source

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Schema

  @type handler :: LocalOperations.handler()
  @type operation_def :: %{
          required(:name) => String.t(),
          required(:handler) => handler(),
          optional(:description) => String.t(),
          optional(:idempotency) => Operation.idempotency(),
          optional(:kind) => atom(),
          optional(:metadata) => map()
        }
  @type t :: %__MODULE__{operations: [operation_def()]}

  defstruct operations: []

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, operations} <- normalize_operations(Schema.get_key(attrs, :operations, [])) do
      {:ok, %__MODULE__{operations: operations}}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, source} ->
        source

      {:error, reason} ->
        raise ArgumentError, "invalid local operation source: #{inspect(reason)}"
    end
  end

  @impl true
  def operations(%__MODULE__{operations: operations}, _opts) do
    {:ok, Enum.map(operations, &operation_spec!/1)}
  end

  @impl true
  def capability(%__MODULE__{operations: operations}, _opts) do
    handlers = Map.new(operations, &{&1.name, &1.handler})
    {:ok, LocalOperations.operations(handlers)}
  end

  defp normalize_operations(operations) when is_list(operations) do
    operations
    |> Enum.reduce_while({:ok, []}, fn operation, {:ok, operations} ->
      case normalize_operation(operation) do
        {:ok, operation} -> {:cont, {:ok, operations ++ [operation]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_operations(operations), do: {:error, {:invalid_local_operations, operations}}

  defp normalize_operation(operation) do
    attrs = Schema.normalize_attrs(operation)
    handler = Schema.get_key(attrs, :handler)

    cond do
      not valid_handler?(handler) ->
        {:error, {:invalid_operation_handler, handler}}

      true ->
        with {:ok, spec} <- operation_spec(attrs) do
          {:ok,
           %{
             name: spec.name,
             description: spec.description,
             idempotency: spec.idempotency,
             kind: Operation.kind(spec),
             metadata: spec.metadata,
             handler: handler
           }}
        end
    end
  end

  defp operation_spec(attrs) do
    kind = Schema.get_key(attrs, :kind, :tool)
    metadata = Schema.get_key(attrs, :metadata, %{})

    Operation.new(
      name: Schema.get_key(attrs, :name),
      description: Schema.get_key(attrs, :description),
      idempotency: Schema.get_key(attrs, :idempotency, :idempotent),
      metadata:
        metadata
        |> Map.put_new("source", "local")
        |> Map.put_new("kind", kind)
    )
  end

  defp operation_spec!(operation) do
    Operation.new!(
      name: operation.name,
      description: operation.description,
      idempotency: operation.idempotency,
      metadata: operation.metadata
    )
  end

  defp valid_handler?(handler), do: is_function(handler, 1) or is_function(handler, 2)
end
