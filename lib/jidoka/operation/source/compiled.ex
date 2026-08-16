defmodule Jidoka.Operation.Source.Compiled do
  @moduledoc """
  Atomic snapshot of one operation source.

  The operation contracts, routes, metadata, and digest in this value come
  from one source compilation.
  """

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Operation.Capability
  alias Jidoka.Operation.Registry
  alias Jidoka.Portable
  alias Jidoka.Replay.Codec

  @enforce_keys [:operations, :routes_by_name, :metadata, :digest]
  defstruct operations: [], routes_by_name: %{}, metadata: [], digest: nil

  @type t :: %__MODULE__{
          operations: [Operation.t()],
          routes_by_name: %{required(String.t()) => Capability.t()},
          metadata: [map()],
          digest: String.t()
        }

  @doc "Builds and validates one compiled source snapshot."
  @spec new([Operation.t() | keyword() | map()], map(), [map()]) ::
          {:ok, t()} | {:error, term()}
  def new(operations, routes_by_name, metadata)
      when is_list(operations) and is_map(routes_by_name) and is_list(metadata) do
    with {:ok, registry} <- normalize_operations(operations),
         operations = Registry.operations(registry),
         :ok <- validate_metadata(metadata),
         :ok <- validate_routes(operations, routes_by_name) do
      {:ok,
       %__MODULE__{
         operations: operations,
         routes_by_name: routes_by_name,
         metadata: metadata,
         digest: digest(operations, metadata)
       }}
    end
  end

  def new(operations, routes_by_name, metadata),
    do: {:error, {:invalid_compiled_operation_source, operations, routes_by_name, metadata}}

  defp normalize_operations(operations) do
    case Registry.new([], operations) do
      {:ok, registry} -> {:ok, registry}
      {:error, {:duplicate_operation_name, name}} -> {:error, {:duplicate_operation_source_name, name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_metadata(metadata) do
    if Enum.all?(metadata, &is_map/1),
      do: :ok,
      else: {:error, {:invalid_operation_source_metadata, metadata}}
  end

  defp validate_routes(operations, routes_by_name) do
    names = MapSet.new(operations, & &1.name)
    route_names = routes_by_name |> Map.keys() |> MapSet.new()

    with :ok <- validate_missing_routes(names, route_names),
         :ok <- validate_extra_routes(names, route_names) do
      Enum.reduce_while(routes_by_name, :ok, fn
        {_name, route}, :ok when is_function(route, 3) -> {:cont, :ok}
        {name, route}, :ok -> {:halt, {:error, {:invalid_operation_source_route, name, route}}}
      end)
    end
  end

  defp validate_missing_routes(names, route_names) do
    case names |> MapSet.difference(route_names) |> Enum.sort() do
      [] -> :ok
      [name | _rest] -> {:error, {:missing_operation_source_route, name}}
    end
  end

  defp validate_extra_routes(names, route_names) do
    case route_names |> MapSet.difference(names) |> Enum.sort() do
      [] -> :ok
      [name | _rest] -> {:error, {:unadvertised_operation_source_route, name}}
    end
  end

  defp digest(operations, metadata) do
    Codec.digest(%{
      "operations" => Portable.project(operations),
      "metadata" => Portable.project(metadata)
    })
  end
end
