defmodule Jidoka.Session.Store do
  @moduledoc """
  Behaviour and delegator for durable session storage.

  Store implementations persist `Jidoka.Session.Data` values. Lease-aware
  stores also provide atomic claim, checkpoint, commit, renewal, and recovery
  transitions. Runtime clients and provider credentials never enter the store.
  """

  alias Jidoka.Session.Data
  alias Jidoka.Session.Transitions
  alias Jidoka.Snapshot
  alias Jidoka.Turn

  @type store :: module() | {module(), keyword()}

  @doc "Persists a caller-managed or inactive session."
  @callback put_session(Data.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}

  @doc "Loads a session by its identifier."
  @callback get_session(String.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}

  @doc "Lists the sessions available to the store."
  @callback list_sessions(keyword()) :: {:ok, [Data.t()]} | {:error, term()}

  @doc "Atomically claims a session for a new request."
  @callback claim_session(String.t(), Turn.Request.t(), keyword()) ::
              {:ok, Data.t()} | {:error, term()}

  @doc "Atomically claims a hibernated session for resume."
  @callback claim_resume(String.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}

  @doc "Atomically replaces an expired lease for crash recovery."
  @callback recover_session(String.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}

  @doc "Atomically records a snapshot under an active lease."
  @callback checkpoint_session(String.t(), String.t(), Snapshot.t(), keyword()) ::
              {:ok, Data.t()} | {:error, term()}

  @doc "Atomically commits final session state and releases its lease."
  @callback commit_session(String.t(), String.t(), Data.t(), keyword()) ::
              {:ok, Data.t()} | {:error, term()}

  @doc "Atomically extends an active lease."
  @callback renew_session(String.t(), String.t(), keyword()) ::
              {:ok, Data.t()} | {:error, term()}

  @optional_callbacks claim_session: 3,
                      claim_resume: 2,
                      recover_session: 2,
                      checkpoint_session: 4,
                      commit_session: 4,
                      renew_session: 3

  @doc "Persists a session through a store module or configured store tuple."
  @spec put_session(store(), Data.t()) :: {:ok, Data.t()} | {:error, term()}
  def put_session(store, %Data{} = session) do
    {module, opts} = normalize_store(store)
    module.put_session(session, opts)
  end

  @doc "Loads a session through a store module or configured store tuple."
  @spec get_session(store(), String.t()) :: {:ok, Data.t()} | {:error, term()}
  def get_session(store, session_id) when is_binary(session_id) do
    {module, opts} = normalize_store(store)
    module.get_session(session_id, opts)
  end

  @doc "Lists sessions through a store module or configured store tuple."
  @spec list_sessions(store()) :: {:ok, [Data.t()]} | {:error, term()}
  def list_sessions(store) do
    {module, opts} = normalize_store(store)
    module.list_sessions(opts)
  end

  @doc "Claims a session for one new request and rejects concurrent use."
  @spec claim_session(store(), String.t(), Turn.Request.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def claim_session(store, session_id, request, opts \\ [])

  def claim_session(store, session_id, %Turn.Request{} = request, opts)
      when is_binary(session_id) and is_list(opts) do
    {module, store_opts} = normalize_store(store)

    if function_exported?(module, :claim_session, 3) do
      module.claim_session(session_id, request, Keyword.merge(store_opts, opts))
    else
      claim_session_fallback(module, store_opts, session_id, request)
    end
  end

  @doc "Claims a stored hibernated session for one resume worker."
  @spec claim_resume(store(), String.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}
  def claim_resume(store, session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    call_durable(store, :claim_resume, [session_id], opts)
  end

  @doc "Replaces an expired lease and returns a crash-recoverable session."
  @spec recover_session(store(), String.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}
  def recover_session(store, session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    call_durable(store, :recover_session, [session_id], opts)
  end

  @doc "Persists one in-run snapshot under the current lease."
  @spec checkpoint_session(store(), String.t(), String.t(), Snapshot.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def checkpoint_session(store, session_id, lease_id, snapshot, opts \\ [])

  def checkpoint_session(
        store,
        session_id,
        lease_id,
        %Snapshot{} = snapshot,
        opts
      )
      when is_binary(session_id) and is_binary(lease_id) and is_list(opts) do
    call_durable(store, :checkpoint_session, [session_id, lease_id, snapshot], opts)
  end

  @doc "Commits terminal or hibernated state under the current lease."
  @spec commit_session(store(), String.t(), String.t(), Data.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def commit_session(store, session_id, lease_id, session, opts \\ [])

  def commit_session(store, session_id, lease_id, %Data{} = session, opts)
      when is_binary(session_id) and is_binary(lease_id) and is_list(opts) do
    call_durable(store, :commit_session, [session_id, lease_id, session], opts)
  end

  @doc "Extends the current session lease."
  @spec renew_session(store(), String.t(), String.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def renew_session(store, session_id, lease_id, opts \\ [])
      when is_binary(session_id) and is_binary(lease_id) and is_list(opts) do
    call_durable(store, :renew_session, [session_id, lease_id], opts)
  end

  @doc "Lists sessions whose worker lease expired and which have a snapshot."
  @spec list_recoverable(store(), keyword()) :: {:ok, [Data.t()]} | {:error, term()}
  def list_recoverable(store, opts \\ []) when is_list(opts) do
    now_ms = clock_ms(opts)

    with {:ok, sessions} <- list_sessions(store) do
      recoverable =
        sessions
        |> Enum.filter(&Transitions.recoverable?(&1, now_ms))
        |> Enum.sort_by(& &1.session_id)

      {:ok, recoverable}
    end
  end

  @doc "Lists pending review requests across stored sessions."
  @spec pending_reviews(store()) :: {:ok, [Jidoka.Review.Request.t()]} | {:error, term()}
  def pending_reviews(store) do
    with {:ok, sessions} <- list_sessions(store) do
      {:ok, Enum.flat_map(sessions, &Data.pending_reviews/1)}
    end
  end

  @doc false
  @spec put_transition(Data.t() | nil, Data.t()) ::
          {:ok, Data.t()} | {:error, term()}
  def put_transition(current, incoming), do: Transitions.put(current, incoming)

  @doc false
  @spec claim_transition(Data.t(), Turn.Request.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def claim_transition(%Data{} = session, %Turn.Request{} = request, opts),
    do: Transitions.claim(session, request, opts)

  @doc false
  @spec resume_transition(Data.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}
  def resume_transition(%Data{} = session, opts), do: Transitions.resume(session, opts)

  @doc false
  @spec recover_transition(Data.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}
  def recover_transition(%Data{} = session, opts), do: Transitions.recover(session, opts)

  @doc false
  @spec checkpoint_transition(Data.t(), String.t(), Snapshot.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def checkpoint_transition(%Data{} = session, lease_id, %Snapshot{} = snapshot, opts),
    do: Transitions.checkpoint(session, lease_id, snapshot, opts)

  @doc false
  @spec commit_transition(Data.t(), String.t(), Data.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def commit_transition(%Data{} = current, lease_id, %Data{} = completed, opts),
    do: Transitions.commit(current, lease_id, completed, opts)

  @doc false
  @spec renew_transition(Data.t(), String.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def renew_transition(%Data{} = session, lease_id, opts),
    do: Transitions.renew(session, lease_id, opts)

  defp call_durable(store, callback, args, runtime_opts) do
    {module, store_opts} = normalize_store(store)
    arity = length(args) + 1

    if function_exported?(module, callback, arity) do
      apply(module, callback, args ++ [Keyword.merge(store_opts, runtime_opts)])
    else
      {:error, {:durable_store_capability_missing, module, callback}}
    end
  end

  defp claim_session_fallback(module, opts, session_id, request) do
    with {:ok, session} <- module.get_session(session_id, opts),
         {:ok, session} <- Transitions.claim_without_lease(session, request) do
      module.put_session(session, opts)
    end
  end

  defp clock_ms(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _clock -> System.system_time(:millisecond)
    end
  end

  defp normalize_store({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp normalize_store(module) when is_atom(module), do: {module, []}
end
