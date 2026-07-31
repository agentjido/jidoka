defmodule Jidoka.Memory.Store do
  @moduledoc """
  Behaviour and delegator for agent memory stores.
  """

  alias Jidoka.Memory.Entry
  alias Jidoka.Memory.RecallRequest
  alias Jidoka.Memory.RecallResult
  alias Jidoka.Memory.WriteRequest
  alias Jidoka.Memory.WriteResult

  @type store :: module() | {module(), keyword()}

  @doc "Recalls memory entries for a normalized request."
  @callback recall(RecallRequest.t(), keyword()) :: {:ok, RecallResult.t()} | {:error, term()}

  @doc "Persists one normalized memory write."
  @callback write(WriteRequest.t(), keyword()) :: {:ok, WriteResult.t()} | {:error, term()}

  @doc "Lists entries available to the store."
  @callback list_entries(keyword()) :: {:ok, [Entry.t()]} | {:error, term()}

  @doc "Recalls entries through a store module or configured store tuple."
  @spec recall(store(), RecallRequest.t()) :: {:ok, RecallResult.t()} | {:error, term()}
  def recall(store, %RecallRequest{} = request) do
    {module, opts} = normalize_store(store)
    module.recall(request, opts)
  end

  @doc "Writes an entry through a store module or configured store tuple."
  @spec write(store(), WriteRequest.t()) :: {:ok, WriteResult.t()} | {:error, term()}
  def write(store, %WriteRequest{} = request) do
    {module, opts} = normalize_store(store)
    module.write(request, opts)
  end

  @doc "Lists entries through a store module or configured store tuple."
  @spec list_entries(store()) :: {:ok, [Entry.t()]} | {:error, term()}
  def list_entries(store) do
    {module, opts} = normalize_store(store)
    module.list_entries(opts)
  end

  defp normalize_store({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp normalize_store(module) when is_atom(module), do: {module, []}
end
