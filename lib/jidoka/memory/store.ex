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

  @callback recall(RecallRequest.t(), keyword()) :: {:ok, RecallResult.t()} | {:error, term()}
  @callback write(WriteRequest.t(), keyword()) :: {:ok, WriteResult.t()} | {:error, term()}
  @callback list_entries(keyword()) :: {:ok, [Entry.t()]} | {:error, term()}

  @spec recall(store(), RecallRequest.t()) :: {:ok, RecallResult.t()} | {:error, term()}
  def recall(store, %RecallRequest{} = request) do
    {module, opts} = normalize_store(store)
    module.recall(request, opts)
  end

  @spec write(store(), WriteRequest.t()) :: {:ok, WriteResult.t()} | {:error, term()}
  def write(store, %WriteRequest{} = request) do
    {module, opts} = normalize_store(store)
    module.write(request, opts)
  end

  @spec list_entries(store()) :: {:ok, [Entry.t()]} | {:error, term()}
  def list_entries(store) do
    {module, opts} = normalize_store(store)
    module.list_entries(opts)
  end

  defp normalize_store({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp normalize_store(module) when is_atom(module), do: {module, []}
end
