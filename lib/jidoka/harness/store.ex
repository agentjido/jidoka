defmodule Jidoka.Harness.Store do
  @moduledoc """
  Behaviour and delegator for harness session storage.

  Store implementations persist `Jidoka.Harness.Session` data. They should not
  know about provider clients, process state, or private Runic internals.
  """

  alias Jidoka.Harness.Session
  alias Jidoka.Turn

  @type store :: module() | {module(), keyword()}

  @callback put_session(Session.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  @callback get_session(String.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  @callback list_sessions(keyword()) :: {:ok, [Session.t()]} | {:error, term()}
  @callback claim_session(String.t(), Turn.Request.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}

  @optional_callbacks claim_session: 3

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

  @spec claim_session(store(), String.t(), Turn.Request.t()) :: {:ok, Session.t()} | {:error, term()}
  def claim_session(store, session_id, %Turn.Request{} = request) when is_binary(session_id) do
    {module, opts} = normalize_store(store)

    if function_exported?(module, :claim_session, 3) do
      module.claim_session(session_id, request, opts)
    else
      claim_session_fallback(module, opts, session_id, request)
    end
  end

  @spec pending_reviews(store()) :: {:ok, [Jidoka.Review.Request.t()]} | {:error, term()}
  def pending_reviews(store) do
    with {:ok, sessions} <- list_sessions(store) do
      {:ok, Enum.flat_map(sessions, & &1.pending_reviews)}
    end
  end

  defp claim_session_fallback(module, opts, session_id, request) do
    with {:ok, session} <- module.get_session(session_id, opts),
         :ok <- ensure_claimable(session),
         session <- Session.put_request(session, request) do
      module.put_session(session, opts)
    end
  end

  defp ensure_claimable(%Session{status: :running, session_id: session_id}) do
    {:error, {:session_already_running, session_id}}
  end

  defp ensure_claimable(%Session{}), do: :ok

  defp normalize_store({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp normalize_store(module) when is_atom(module), do: {module, []}
end
