defmodule Jidoka.Handoff.OwnerStore do
  @moduledoc """
  Storage boundary for conversation handoff owners.

  The default store is process-local ETS for examples and tests. Applications
  that need durable or clustered ownership can configure another module:

      config :jidoka, :handoff_owner_store, MyApp.HandoffOwnerStore
  """

  alias Jidoka.Handoff

  @default_store :"Elixir.Jidoka.Handoff.OwnerStore.InMemory"

  @type owner :: %{
          required(:agent) => module(),
          required(:agent_id) => String.t(),
          required(:handoff) => Handoff.t(),
          required(:updated_at_ms) => integer()
        }

  @doc "Returns the current owner record for a conversation."
  @callback owner(String.t()) :: owner() | nil

  @doc "Stores the handoff owner for a conversation."
  @callback put_owner(String.t(), Handoff.t()) :: :ok

  @doc "Removes the handoff owner for a conversation."
  @callback reset(String.t()) :: :ok

  @doc "Returns the configured owner-store module."
  @spec store() :: module()
  def store, do: Application.get_env(:jidoka, :handoff_owner_store, @default_store)

  @doc "Returns the current owner record from the configured store."
  @spec owner(String.t()) :: owner() | nil
  def owner(conversation_id) when is_binary(conversation_id), do: store().owner(conversation_id)
  def owner(_conversation_id), do: nil

  @doc "Stores a handoff owner when a conversation identifier is available."
  @spec put_owner(String.t() | nil, Handoff.t()) :: :ok
  def put_owner(conversation_id, %Handoff{} = handoff) when is_binary(conversation_id),
    do: store().put_owner(conversation_id, handoff)

  def put_owner(_conversation_id, _handoff), do: :ok

  @doc "Removes a handoff owner when a conversation identifier is valid."
  @spec reset(String.t()) :: :ok
  def reset(conversation_id) when is_binary(conversation_id), do: store().reset(conversation_id)
  def reset(_conversation_id), do: :ok
end
