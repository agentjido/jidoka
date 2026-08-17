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

  @doc "Starts the process-local handoff owner store."
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
      [{^conversation_id, record}] -> normalize_owner(conversation_id, record)
      [] -> nil
    end
  end

  @impl true
  def put_owner(conversation_id, %Handoff{conversation_id: conversation_id} = handoff)
      when is_binary(conversation_id) and conversation_id != "" do
    record = %{handoff: handoff, updated_at_ms: System.system_time(:millisecond)}

    true = :ets.insert(@table, {conversation_id, record})
    :ok
  end

  def put_owner(conversation_id, %Handoff{conversation_id: handoff_id}),
    do: {:error, {:handoff_conversation_id_mismatch, conversation_id, handoff_id}}

  @impl true
  def reset(conversation_id) when is_binary(conversation_id) do
    :ets.delete(@table, conversation_id)
    :ok
  end

  defp normalize_owner(conversation_id, %{handoff: %Handoff{} = handoff, updated_at_ms: updated_at_ms}) do
    with {:ok, handoff} <- normalize_handoff(conversation_id, handoff) do
      record = %{handoff: handoff, updated_at_ms: updated_at_ms}
      true = :ets.insert(@table, {conversation_id, record})

      %{
        conversation_id: handoff.conversation_id,
        agent: handoff.to_agent,
        agent_id: handoff.to_agent_id,
        handoff: handoff,
        updated_at_ms: updated_at_ms
      }
    else
      {:error, _reason} -> nil
    end
  end

  defp normalize_owner(_conversation_id, _record), do: nil

  defp normalize_handoff(conversation_id, %Handoff{conversation_id: nil} = handoff) do
    handoff
    |> Map.put(:conversation_id, conversation_id)
    |> Handoff.from_input()
  end

  defp normalize_handoff(conversation_id, %Handoff{} = handoff) do
    with {:ok, handoff} <- Handoff.from_input(handoff),
         true <- handoff.conversation_id == conversation_id do
      {:ok, handoff}
    else
      false -> {:error, {:handoff_conversation_id_mismatch, conversation_id, handoff.conversation_id}}
      {:error, _reason} = error -> error
    end
  end
end
