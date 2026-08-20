defmodule Jidoka.Operation.Source do
  @moduledoc """
  Behaviour and compiler for operation sources.

  Each source returns one atomic compiled value. That value contains ordered
  operation contracts, one exact route for each operation name, portable
  metadata, and a stable contract digest.
  """

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Operation.Capability
  alias Jidoka.Operation.Registry
  alias Jidoka.Operation.Source.Compiled
  alias Jidoka.Replay.Codec

  @type source :: struct()
  @type compiled :: %{
          operations: [Operation.t()],
          routes_by_name: %{required(String.t()) => Capability.t()},
          capability: Capability.t(),
          metadata: [map()],
          digest: String.t() | nil
        }

  @doc "Compiles one source into one atomic snapshot."
  @callback compile(source(), keyword()) :: {:ok, Compiled.t()} | {:error, term()}

  @doc false
  @callback operations(source(), keyword()) :: {:ok, [Operation.t()]} | {:error, term()}

  @doc false
  @callback capability(source(), keyword()) :: {:ok, Capability.t()} | {:error, term()}

  @doc false
  @callback metadata(source(), keyword()) :: {:ok, [map()]} | {:error, term()}

  @optional_callbacks compile: 2, operations: 2, capability: 2, metadata: 2

  @doc "Builds one compiled snapshot when all operation names use one capability."
  @spec compiled([Operation.t()], Capability.t(), [map()]) ::
          {:ok, Compiled.t()} | {:error, term()}
  def compiled(operations, capability, metadata \\ [])
      when is_list(operations) and is_function(capability, 3) and is_list(metadata) do
    with {:ok, registry} <- Registry.new([], operations) do
      operations = Registry.operations(registry)
      routes_by_name = Map.new(operations, &{&1.name, capability})
      Compiled.new(operations, routes_by_name, metadata)
    end
  end

  @doc "Loads one atomic source snapshot."
  @spec load(source(), keyword()) :: {:ok, Compiled.t()} | {:error, term()}
  def load(source, opts \\ [])

  def load(%Compiled{} = compiled, _opts) do
    Compiled.new(compiled.operations, compiled.routes_by_name, compiled.metadata)
  end

  def load(%module{} = source, opts) when is_list(opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :compile, 2) do
      case module.compile(source, opts) do
        {:ok, %Compiled{} = compiled} ->
          Compiled.new(compiled.operations, compiled.routes_by_name, compiled.metadata)

        {:ok, invalid} ->
          {:error, {:invalid_compiled_operation_source, module, invalid}}

        {:error, _reason} = error ->
          error
      end
    else
      load_legacy(module, source, opts)
    end
  end

  @doc "Loads model-visible operations from one source snapshot."
  @spec operations(source(), keyword()) :: {:ok, [Operation.t()]} | {:error, term()}
  def operations(source, opts \\ []) do
    with {:ok, compiled} <- load(source, opts), do: {:ok, compiled.operations}
  end

  @doc "Loads one routed capability from one source snapshot."
  @spec capability(source(), keyword()) :: {:ok, Capability.t()} | {:error, term()}
  def capability(source, opts \\ []) do
    with {:ok, compiled} <- load(source, opts), do: {:ok, route_capability(compiled.routes_by_name)}
  end

  @doc "Loads portable metadata from one source snapshot."
  @spec metadata(source(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def metadata(source, opts \\ []) do
    with {:ok, compiled} <- load(source, opts), do: {:ok, compiled.metadata}
  end

  @doc "Compiles one or more sources into one ordered routed capability."
  @spec compile([source()] | source(), keyword()) :: {:ok, compiled()} | {:error, term()}
  def compile(sources, opts \\ []) do
    sources = List.wrap(sources)

    with {:ok, entries} <- compile_sources(sources, opts),
         {:ok, registry} <- registry(entries),
         {:ok, routes_by_name} <- merge_routes(entries) do
      {:ok,
       %{
         operations: Registry.operations(registry),
         routes_by_name: routes_by_name,
         capability: route_capability(routes_by_name),
         metadata: Enum.flat_map(entries, & &1.metadata),
         digest: digest(entries)
       }}
    end
  end

  @doc false
  @spec route_capability(map()) :: Capability.t()
  def route_capability(routes_by_name) when is_map(routes_by_name) do
    fn
      %Effect.Intent{kind: :operation, payload: payload} = intent,
      %Effect.Journal{} = journal,
      %Jidoka.Context{} = ctx ->
        with {:ok, request} <- Effect.OperationRequest.from_input(payload),
             {:ok, capability} <- fetch_route(routes_by_name, request.name) do
          capability.(intent, journal, ctx)
        end

      %Effect.Intent{kind: kind}, _journal, %Jidoka.Context{} ->
        {:error, {:unsupported_effect_kind, kind}}
    end
  end

  defp compile_sources(sources, opts) do
    Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, entries} ->
      case load(source, opts) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end)
  end

  defp load_legacy(module, source, opts) do
    with true <- function_exported?(module, :operations, 2),
         true <- function_exported?(module, :capability, 2),
         {:ok, operations} <- module.operations(source, opts),
         {:ok, capability} <- module.capability(source, opts),
         {:ok, metadata} <- legacy_metadata(module, source, opts) do
      compiled(operations, capability, metadata)
    else
      false -> {:error, {:invalid_operation_source, module}}
      {:error, _reason} = error -> error
    end
  end

  defp legacy_metadata(module, source, opts) do
    if function_exported?(module, :metadata, 2),
      do: module.metadata(source, opts),
      else: {:ok, []}
  end

  defp registry(entries) do
    case Registry.new([], Enum.flat_map(entries, & &1.operations)) do
      {:ok, registry} -> {:ok, registry}
      {:error, {:duplicate_operation_name, name}} -> {:error, {:duplicate_operation_source_name, name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_routes(entries) do
    {:ok, entries |> Enum.flat_map(&Map.to_list(&1.routes_by_name)) |> Map.new()}
  end

  defp fetch_route(routes_by_name, name) do
    case Map.fetch(routes_by_name, name) do
      {:ok, capability} -> {:ok, capability}
      :error -> {:error, {:missing_operation_handler, name}}
    end
  end

  defp digest([]), do: nil
  defp digest(entries), do: Codec.digest(Enum.map(entries, & &1.digest))
end
