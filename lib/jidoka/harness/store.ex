defmodule Jidoka.Harness.Store do
  @moduledoc """
  Behaviour and delegator for harness session storage.

  Store implementations persist `Jidoka.Harness.Session` data. They should not
  know about provider clients, process state, or private Runic internals.
  """

  alias Jidoka.Harness.Session

  @type store :: module() | {module(), keyword()}

  @callback put_session(Session.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  @callback get_session(String.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  @callback list_sessions(keyword()) :: {:ok, [Session.t()]} | {:error, term()}

  @spec put_session(store(), Session.t()) :: {:ok, Session.t()} | {:error, term()}
  def put_session(store, %Session{} = session) do
    {module, opts} = normalize_store(store)
    module.put_session(session, opts)
  end

  @spec get_session(store(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def get_session(store, session_id) when is_binary(session_id) do
    {module, opts} = normalize_store(store)
    module.get_session(session_id, opts)
  end

  @spec list_sessions(store()) :: {:ok, [Session.t()]} | {:error, term()}
  def list_sessions(store) do
    {module, opts} = normalize_store(store)
    module.list_sessions(opts)
  end

  @spec pending_reviews(store()) :: {:ok, [Jidoka.Review.Request.t()]} | {:error, term()}
  def pending_reviews(store) do
    with {:ok, sessions} <- list_sessions(store) do
      {:ok, Enum.flat_map(sessions, & &1.pending_reviews)}
    end
  end

  defp normalize_store({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp normalize_store(module) when is_atom(module), do: {module, []}
end
