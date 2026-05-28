defmodule Jidoka.Handoff.OwnerStore do
  @moduledoc """
  Behaviour for storing conversation handoff ownership.

  Handoff ownership is keyed by conversation id. The default implementation is
  `Jidoka.Handoff.Registry`, an in-memory process-local store intended for
  development, tests, and single-node runtimes.

  Applications that need ownership to survive process restarts, deploys, or
  cluster routing can provide another module with this behaviour and configure
  Jidoka to call that store instead:

      config :jidoka, :handoff_owner_store, MyApp.HandoffOwnerStore
  """

  @default_store Jidoka.Handoff.Registry

  @type owner :: %{
          agent: module(),
          agent_id: String.t(),
          handoff: Jidoka.Handoff.t(),
          updated_at_ms: integer()
        }

  @callback owner(conversation_id :: String.t()) :: owner() | nil
  @callback put_owner(conversation_id :: String.t(), handoff :: Jidoka.Handoff.t()) :: :ok
  @callback reset(conversation_id :: String.t()) :: :ok

  @doc false
  @spec default_store() :: module()
  def default_store, do: @default_store

  @doc false
  @spec store() :: module()
  def store, do: Application.get_env(:jidoka, :handoff_owner_store, @default_store)

  @doc false
  @spec owner(String.t()) :: owner() | nil
  def owner(conversation_id) when is_binary(conversation_id), do: store().owner(conversation_id)
  def owner(_conversation_id), do: nil

  @doc false
  @spec put_owner(String.t(), Jidoka.Handoff.t()) :: :ok
  def put_owner(conversation_id, %Jidoka.Handoff{} = handoff) when is_binary(conversation_id) do
    store().put_owner(conversation_id, handoff)
  end

  def put_owner(_conversation_id, _handoff), do: :ok

  @doc false
  @spec reset(String.t()) :: :ok
  def reset(conversation_id) when is_binary(conversation_id), do: store().reset(conversation_id)
  def reset(_conversation_id), do: :ok
end
