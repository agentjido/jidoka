defmodule Jidoka.Runtime.EventSequence do
  @moduledoc false

  use GenServer

  alias Jidoka.Event

  @table __MODULE__

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc false
  @spec stamp(Event.t()) :: Event.t()
  def stamp(%Event{request_id: request_id, event: :turn_started} = event)
      when is_binary(request_id) do
    true = :ets.insert(@table, {request_id, 1})
    %Event{event | seq: 0}
  rescue
    ArgumentError -> event
  end

  def stamp(%Event{request_id: request_id} = event) when is_binary(request_id) do
    seq = :ets.update_counter(@table, request_id, {2, 1}, {request_id, 0}) - 1
    stamped = %Event{event | seq: seq}

    if event.event in [:turn_finished, :turn_failed, :turn_hibernated] do
      :ets.delete(@table, request_id)
    end

    stamped
  rescue
    ArgumentError -> event
  end

  def stamp(%Event{} = event), do: event

  @impl true
  def init(state) do
    @table = :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    {:ok, state}
  end
end
