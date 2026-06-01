defmodule Jidoka.Handoff.OwnerStore.InMemory do
  @moduledoc """
  ETS-backed handoff owner store for local runtimes, examples, and tests.
  """

  @behaviour Jidoka.Handoff.OwnerStore

  alias Jidoka.Handoff

  @table :jidoka_handoff_owners

  @impl true
  def owner(conversation_id) when is_binary(conversation_id) do
    case :ets.lookup(table(), conversation_id) do
      [{^conversation_id, owner}] -> owner
      [] -> nil
    end
  end

  @impl true
  def put_owner(conversation_id, %Handoff{} = handoff) when is_binary(conversation_id) do
    owner = %{
      agent: handoff.to_agent,
      agent_id: handoff.to_agent_id,
      handoff: handoff,
      updated_at_ms: System.system_time(:millisecond)
    }

    true = :ets.insert(table(), {conversation_id, owner})
    :ok
  end

  @impl true
  def reset(conversation_id) when is_binary(conversation_id) do
    :ets.delete(table(), conversation_id)
    :ok
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      table ->
        table
    end
  rescue
    ArgumentError ->
      :ets.whereis(@table)
  end
end
