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

  @callback owner(String.t()) :: owner() | nil
  @callback put_owner(String.t(), Handoff.t()) :: :ok
  @callback reset(String.t()) :: :ok

  @spec store() :: module()
  def store, do: Application.get_env(:jidoka, :handoff_owner_store, @default_store)

  @spec owner(String.t()) :: owner() | nil
  def owner(conversation_id) when is_binary(conversation_id), do: store().owner(conversation_id)
  def owner(_conversation_id), do: nil

  @spec put_owner(String.t() | nil, Handoff.t()) :: :ok
  def put_owner(conversation_id, %Handoff{} = handoff) when is_binary(conversation_id),
    do: store().put_owner(conversation_id, handoff)

  def put_owner(_conversation_id, _handoff), do: :ok

  @spec reset(String.t()) :: :ok
  def reset(conversation_id) when is_binary(conversation_id), do: store().reset(conversation_id)
  def reset(_conversation_id), do: :ok
end
