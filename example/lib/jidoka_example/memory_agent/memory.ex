defmodule JidokaExample.MemoryAgent.Memory do
  @moduledoc false

  @table :jidoka_example_memory
  @namespace "jidoka_example:memory_agent"

  def ensure_ready! do
    :ok = Jido.Memory.Store.ETS.ensure_ready(table: @table)
  end

  def store do
    {Jidoka.Memory.Store.JidoMemory,
     namespace: @namespace, provider_opts: [store: {Jido.Memory.Store.ETS, [table: @table]}]}
  end

  def store(session_id) when is_binary(session_id) do
    {Jidoka.Memory.Store.JidoMemory,
     namespace: @namespace,
     scope: :session,
     session_id: session_id,
     provider_opts: [store: {Jido.Memory.Store.ETS, [table: @table]}]}
  end
end
