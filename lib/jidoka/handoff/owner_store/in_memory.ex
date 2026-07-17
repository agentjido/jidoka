defmodule Jidoka.Handoff.OwnerStore.InMemory do
  @moduledoc """
  Supervised ETS-backed handoff owner store for local runtimes, examples, and tests.

  The store process owns the table so entries survive the request or task that
  records a handoff. Entries remain node-local and are lost when the store or
  application restarts.
  """

  use GenServer

  @behaviour Jidoka.Handoff.OwnerStore

  alias Jidoka.Handoff

  @table :jidoka_handoff_owners

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def owner(conversation_id) when is_binary(conversation_id) do
    case :ets.lookup(@table, conversation_id) do
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

    true = :ets.insert(@table, {conversation_id, owner})
    :ok
  end

  @impl true
  def reset(conversation_id) when is_binary(conversation_id) do
    :ets.delete(@table, conversation_id)
    :ok
  end
end
