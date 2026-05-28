defmodule Jidoka.Handoff.Registry do
  @moduledoc false

  use GenServer
  @behaviour Jidoka.Handoff.OwnerStore

  @type owner :: %{
          agent: module(),
          agent_id: String.t(),
          handoff: Jidoka.Handoff.t(),
          updated_at_ms: integer()
        }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @spec owner(String.t()) :: owner() | nil
  @impl Jidoka.Handoff.OwnerStore
  def owner(conversation_id) when is_binary(conversation_id) do
    GenServer.call(__MODULE__, {:owner, conversation_id})
  end

  def owner(_conversation_id), do: nil

  @doc false
  @spec put_owner(String.t(), Jidoka.Handoff.t()) :: :ok
  @impl Jidoka.Handoff.OwnerStore
  def put_owner(conversation_id, %Jidoka.Handoff{} = handoff) when is_binary(conversation_id) do
    GenServer.call(__MODULE__, {:put_owner, conversation_id, handoff})
  end

  def put_owner(_conversation_id, _handoff), do: :ok

  @doc false
  @spec reset(String.t()) :: :ok
  @impl Jidoka.Handoff.OwnerStore
  def reset(conversation_id) when is_binary(conversation_id) do
    GenServer.call(__MODULE__, {:reset, conversation_id})
  end

  def reset(_conversation_id), do: :ok

  @doc false
  @impl true
  def init(_opts), do: {:ok, %{}}

  @doc false
  @impl true
  def handle_call({:owner, conversation_id}, _from, state) do
    {:reply, Map.get(state, conversation_id), state}
  end

  def handle_call({:put_owner, conversation_id, %Jidoka.Handoff{} = handoff}, _from, state) do
    owner = %{
      agent: handoff.to_agent,
      agent_id: handoff.to_agent_id,
      handoff: handoff,
      updated_at_ms: System.system_time(:millisecond)
    }

    {:reply, :ok, Map.put(state, conversation_id, owner)}
  end

  def handle_call({:reset, conversation_id}, _from, state) do
    {:reply, :ok, Map.delete(state, conversation_id)}
  end
end
