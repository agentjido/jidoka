defmodule JidokaExample.AgentSessions do
  @moduledoc false

  use GenServer

  @table __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get(session_id, default_fun) when is_binary(session_id) and is_function(default_fun, 0) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, view}] ->
        view

      [] ->
        view = default_fun.()
        put(session_id, view)
        view
    end
  end

  def put(session_id, view) when is_binary(session_id) do
    true = :ets.insert(@table, {session_id, view})
    :ok
  end

  def reset(session_id, default_fun) when is_binary(session_id) and is_function(default_fun, 0) do
    view = default_fun.()
    put(session_id, view)
    view
  end

  @impl true
  def init(state) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, state}
  end
end
