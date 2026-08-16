defmodule Jidoka.Operation.Source.Defined do
  @moduledoc false

  @behaviour Jidoka.Operation.Source

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Compiled

  @enforce_keys [:source, :operations]
  defstruct [:source, :operations, metadata: []]

  @type t :: %__MODULE__{
          source: Source.source(),
          operations: [Operation.t()],
          metadata: [map()]
        }

  @spec new!(Source.source(), [Operation.t()], [map()]) :: t()
  def new!(%_{} = source, operations, metadata \\ [])
      when is_list(operations) and is_list(metadata) do
    %__MODULE__{source: source, operations: operations, metadata: metadata}
  end

  @impl true
  def compile(%__MODULE__{} = defined, opts) do
    with {:ok, source} <- Source.load(defined.source, opts),
         {:ok, routes_by_name} <- select_routes(defined.operations, source.routes_by_name) do
      Compiled.new(defined.operations, routes_by_name, defined.metadata)
    end
  end

  @impl true
  def operations(%__MODULE__{operations: operations}, _opts), do: {:ok, operations}

  @impl true
  def capability(%__MODULE__{source: source}, opts), do: Source.capability(source, opts)

  @impl true
  def metadata(%__MODULE__{metadata: metadata}, _opts), do: {:ok, metadata}

  defp select_routes(operations, routes_by_name) do
    Enum.reduce_while(operations, {:ok, %{}}, fn operation, {:ok, selected} ->
      case Map.fetch(routes_by_name, operation.name) do
        {:ok, route} -> {:cont, {:ok, Map.put(selected, operation.name, route)}}
        :error -> {:halt, {:error, {:missing_operation_source_route, operation.name}}}
      end
    end)
  end
end
