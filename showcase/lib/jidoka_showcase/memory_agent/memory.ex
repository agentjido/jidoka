defmodule JidokaShowcase.MemoryAgent.Memory do
  @moduledoc false

  @table :jidoka_showcase_memory
  @namespace "jidoka_showcase:memory_agent"

  def ensure_ready! do
    :ok = Jido.Memory.Store.ETS.ensure_ready(table: @table)
  end

  def store do
    {Jidoka.Memory.Store.JidoMemory,
     namespace: @namespace, provider_opts: [store: {Jido.Memory.Store.ETS, [table: @table]}]}
  end

  def store(session_id) when is_binary(session_id) do
    store(session_id, "memory_agent")
  end

  def store(session_id, agent_id) when is_binary(session_id) and is_binary(agent_id) do
    {Jidoka.Memory.Store.JidoMemory,
     agent_id: agent_id,
     session_id: session_id,
     provider_opts: [store: {Jido.Memory.Store.ETS, [table: @table]}]}
  end
end
