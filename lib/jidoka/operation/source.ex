defmodule Jidoka.Operation.Source do
  @moduledoc """
  Behaviour and compiler for operation sources.

  Operation sources normalize external executable surfaces into
  `Jidoka.Agent.Spec.Operation` data plus one runtime capability. The turn loop
  still sees a single operation model.
  """

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect

  @type source :: struct()
  @type compiled :: %{
          operations: [Operation.t()],
          capability: Jidoka.Runtime.Capabilities.operation_capability()
        }

  @callback operations(source(), keyword()) :: {:ok, [Operation.t()]} | {:error, term()}
  @callback capability(source(), keyword()) ::
              {:ok, Jidoka.Runtime.Capabilities.operation_capability()} | {:error, term()}

  @spec operations(source(), keyword()) :: {:ok, [Operation.t()]} | {:error, term()}
  def operations(%module{} = source, opts \\ []) do
    module.operations(source, opts)
  end

  @spec capability(source(), keyword()) ::
          {:ok, Jidoka.Runtime.Capabilities.operation_capability()} | {:error, term()}
  def capability(%module{} = source, opts \\ []) do
    module.capability(source, opts)
  end

  @spec compile([source()] | source(), keyword()) :: {:ok, compiled()} | {:error, term()}
  def compile(sources, opts \\ []) do
    sources = List.wrap(sources)

    with {:ok, entries} <- compile_sources(sources, opts),
         :ok <- validate_unique_names(entries) do
      {:ok,
       %{
         operations: Enum.flat_map(entries, & &1.operations),
         capability: routed_capability(entries)
       }}
    end
  end

  defp compile_sources(sources, opts) do
    Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, entries} ->
      with {:ok, operations} <- operations(source, opts),
           {:ok, capability} <- capability(source, opts) do
        entry = %{source: source, operations: operations, capability: capability}
        {:cont, {:ok, entries ++ [entry]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_unique_names(entries) do
    entries
    |> Enum.flat_map(& &1.operations)
    |> Enum.reduce_while(MapSet.new(), fn %Operation{name: name}, seen ->
      if MapSet.member?(seen, name) do
        {:halt, {:error, {:duplicate_operation_source_name, name}}}
      else
        {:cont, MapSet.put(seen, name)}
      end
    end)
    |> case do
      %MapSet{} -> :ok
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
