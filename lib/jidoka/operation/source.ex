defmodule Jidoka.Operation.Source do
  @moduledoc """
  Behaviour and compiler for operation sources.

  Operation sources normalize external executable surfaces into
  `Jidoka.Agent.Spec.Operation` data plus one runtime capability. The turn loop
  still sees a single operation model.
  """

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Operation.Capability
  alias Jidoka.Operation.Registry

  @type source :: struct()
  @type compiled :: %{
          operations: [Operation.t()],
          capability: Capability.t(),
          metadata: [map()]
        }

  @doc "Returns the model-visible operations exposed by a source."
  @callback operations(source(), keyword()) :: {:ok, [Operation.t()]} | {:error, term()}

  @doc "Returns the runtime capability that executes operations from a source."
  @callback capability(source(), keyword()) ::
              {:ok, Capability.t()} | {:error, term()}

  @doc "Returns portable source metadata when the source supports it."
  @callback metadata(source(), keyword()) :: {:ok, [map()]} | {:error, term()}

  @optional_callbacks metadata: 2

  @doc "Loads model-visible operations from one operation source."
  @spec operations(source(), keyword()) :: {:ok, [Operation.t()]} | {:error, term()}
  def operations(%module{} = source, opts \\ []) do
    module.operations(source, opts)
  end

  @doc "Loads the runtime capability from one operation source."
  @spec capability(source(), keyword()) ::
          {:ok, Capability.t()} | {:error, term()}
  def capability(%module{} = source, opts \\ []) do
    module.capability(source, opts)
  end

  @doc "Loads portable metadata from one operation source."
  @spec metadata(source(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def metadata(%module{} = source, opts \\ []) do
    if function_exported?(module, :metadata, 2) do
      module.metadata(source, opts)
    else
      {:ok, []}
    end
  end

  @doc "Compiles one or more sources into operation data and one routed capability."
  @spec compile([source()] | source(), keyword()) :: {:ok, compiled()} | {:error, term()}
  def compile(sources, opts \\ []) do
    sources = List.wrap(sources)

    with {:ok, entries} <- compile_sources(sources, opts),
         {:ok, registry} <- registry(entries) do
      {:ok,
       %{
         operations: Registry.operations(registry),
         capability: routed_capability(entries),
         metadata: Enum.flat_map(entries, & &1.metadata)
       }}
    end
  end

  defp compile_sources(sources, opts) do
    Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, entries} ->
      with {:ok, operations} <- operations(source, opts),
           {:ok, capability} <- capability(source, opts),
           {:ok, metadata} <- metadata(source, opts) do
        entry = %{source: source, operations: operations, capability: capability, metadata: metadata}
        {:cont, {:ok, entries ++ [entry]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp registry(entries) do
    case Registry.new([], Enum.flat_map(entries, & &1.operations)) do
      {:ok, registry} -> {:ok, registry}
      {:error, {:duplicate_operation_name, name}} -> {:error, {:duplicate_operation_source_name, name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp routed_capability(entries) do
    routes =
      Map.new(entries, fn entry ->
        names = MapSet.new(Enum.map(entry.operations, & &1.name))
        {names, entry.capability}
      end)

    fn
      %Effect.Intent{kind: :operation, payload: payload} = intent,
      %Effect.Journal{} = journal,
      %Jidoka.Context{} = ctx ->
        with {:ok, request} <- Effect.OperationRequest.from_input(payload),
             {:ok, capability} <- route(routes, request.name) do
          capability.(intent, journal, ctx)
        end

      %Effect.Intent{kind: kind}, _journal, %Jidoka.Context{} ->
        {:error, {:unsupported_effect_kind, kind}}
    end
  end

  defp route(routes, name) do
    Enum.find_value(routes, fn {names, capability} ->
      if MapSet.member?(names, name), do: {:ok, capability}
    end) || {:error, {:missing_operation_handler, name}}
  end
end
