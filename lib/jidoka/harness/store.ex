defmodule Jidoka.Harness.Store do
  @moduledoc """
  Behaviour and delegator for harness session storage.

  Store implementations persist `Jidoka.Harness.Session` data. Lease-aware
  stores also provide atomic claim, checkpoint, commit, renewal, and recovery
  transitions. Runtime clients and provider credentials never enter the store.
  """

  alias Jidoka.Harness.Session
  alias Jidoka.Harness.SessionLease
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  @default_lease_ttl_ms 30_000

  @type store :: module() | {module(), keyword()}

  @doc "Persists a caller-managed or inactive harness session."
  @callback put_session(Session.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}

  @doc "Loads a harness session by its identifier."
  @callback get_session(String.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}

  @doc "Lists the harness sessions available to the store."
  @callback list_sessions(keyword()) :: {:ok, [Session.t()]} | {:error, term()}

  @doc "Atomically claims a session for a new request."
  @callback claim_session(String.t(), Turn.Request.t(), keyword()) ::
              {:ok, Session.t()} | {:error, term()}

  @doc "Atomically claims a hibernated session for resume."
  @callback claim_resume(String.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}

  @doc "Atomically replaces an expired lease for crash recovery."
  @callback recover_session(String.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}

  @doc "Atomically records a snapshot under an active lease."
  @callback checkpoint_session(String.t(), String.t(), AgentSnapshot.t(), keyword()) ::
              {:ok, Session.t()} | {:error, term()}

  @doc "Atomically commits final session state and releases its lease."
  @callback commit_session(String.t(), String.t(), Session.t(), keyword()) ::
              {:ok, Session.t()} | {:error, term()}

  @doc "Atomically extends an active lease."
  @callback renew_session(String.t(), String.t(), keyword()) ::
              {:ok, Session.t()} | {:error, term()}

  @optional_callbacks claim_session: 3,
                      claim_resume: 2,
                      recover_session: 2,
                      checkpoint_session: 4,
                      commit_session: 4,
                      renew_session: 3

  @doc "Persists a session through a store module or configured store tuple."
  @spec put_session(store(), Session.t()) :: {:ok, Session.t()} | {:error, term()}
  def put_session(store, %Session{} = session) do
    {module, opts} = normalize_store(store)
    module.put_session(session, opts)
  end

  @doc "Loads a session through a store module or configured store tuple."
  @spec get_session(store(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def get_session(store, session_id) when is_binary(session_id) do
    {module, opts} = normalize_store(store)
    module.get_session(session_id, opts)
  end

  @doc "Lists sessions through a store module or configured store tuple."
  @spec list_sessions(store()) :: {:ok, [Session.t()]} | {:error, term()}
  def list_sessions(store) do
    {module, opts} = normalize_store(store)
    module.list_sessions(opts)
  end

  @doc "Claims a session for one new request and rejects concurrent use."
  @spec claim_session(store(), String.t(), Turn.Request.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
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
  @spec claim_resume(store(), String.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def claim_resume(store, session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    call_durable(store, :claim_resume, [session_id], opts)
  end

  @doc "Replaces an expired lease and returns a crash-recoverable session."
  @spec recover_session(store(), String.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def recover_session(store, session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    call_durable(store, :recover_session, [session_id], opts)
  end

  @doc "Persists one in-run snapshot under the current lease."
  @spec checkpoint_session(store(), String.t(), String.t(), AgentSnapshot.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def checkpoint_session(store, session_id, lease_id, snapshot, opts \\ [])

  def checkpoint_session(
        store,
        session_id,
        lease_id,
        %AgentSnapshot{} = snapshot,
        opts
      )
      when is_binary(session_id) and is_binary(lease_id) and is_list(opts) do
    call_durable(store, :checkpoint_session, [session_id, lease_id, snapshot], opts)
  end

  @doc "Commits terminal or hibernated state under the current lease."
  @spec commit_session(store(), String.t(), String.t(), Session.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def commit_session(store, session_id, lease_id, session, opts \\ [])

  def commit_session(store, session_id, lease_id, %Session{} = session, opts)
      when is_binary(session_id) and is_binary(lease_id) and is_list(opts) do
    call_durable(store, :commit_session, [session_id, lease_id, session], opts)
  end

  @doc "Extends the current session lease."
  @spec renew_session(store(), String.t(), String.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def renew_session(store, session_id, lease_id, opts \\ [])
      when is_binary(session_id) and is_binary(lease_id) and is_list(opts) do
    call_durable(store, :renew_session, [session_id, lease_id], opts)
  end

  @doc "Lists sessions whose worker lease expired and which have a snapshot."
  @spec list_recoverable(store(), keyword()) :: {:ok, [Session.t()]} | {:error, term()}
  def list_recoverable(store, opts \\ []) when is_list(opts) do
    now_ms = clock_ms(opts)

    with {:ok, sessions} <- list_sessions(store) do
      recoverable =
        sessions
        |> Enum.filter(&recoverable?(&1, now_ms))
        |> Enum.sort_by(& &1.session_id)

      {:ok, recoverable}
    end
  end

  @doc "Lists pending review requests across stored sessions."
  @spec pending_reviews(store()) :: {:ok, [Jidoka.Review.Request.t()]} | {:error, term()}
  def pending_reviews(store) do
    with {:ok, sessions} <- list_sessions(store) do
      {:ok, Enum.flat_map(sessions, & &1.pending_reviews)}
    end
  end

  @doc false
  @spec put_transition(Session.t() | nil, Session.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def put_transition(nil, %Session{} = incoming), do: {:ok, incoming}

  def put_transition(%Session{lease: %SessionLease{}, session_id: session_id}, %Session{}) do
    {:error, {:session_lease_required, session_id}}
  end

  def put_transition(
        %Session{session_id: session_id, revision: current_revision},
        %Session{session_id: session_id, revision: incoming_revision} = incoming
      )
      when incoming_revision >= current_revision,
      do: {:ok, incoming}

  def put_transition(%Session{} = current, %Session{} = incoming) do
    {:error, {:stale_session_revision, current.session_id, incoming.session_id, current.revision, incoming.revision}}
  end

  @doc false
  @spec claim_transition(Session.t(), Turn.Request.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def claim_transition(%Session{} = session, %Turn.Request{} = request, opts) do
    with :ok <- ensure_claimable(session),
         {:ok, lease} <- acquire_lease(request.request_id, opts) do
      claimed =
        session
        |> Session.put_request(request)
        |> Session.put_lease(lease)
        |> Session.bump_revision()

      {:ok, claimed}
    end
  end

  @doc false
  @spec resume_transition(Session.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def resume_transition(%Session{} = session, opts) do
    with :ok <- ensure_resumable(session),
         %AgentSnapshot{turn_state: %{request: %Turn.Request{request_id: request_id}}} <-
           Session.latest_snapshot(session),
         {:ok, lease} <- acquire_lease(request_id, opts) do
      {:ok, session |> Session.put_lease(lease) |> Session.bump_revision()}
    else
      nil -> {:error, {:missing_session_snapshot, session.session_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec recover_transition(Session.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def recover_transition(%Session{} = session, opts) do
    now_ms = clock_ms(opts)

    with :ok <- ensure_recoverable(session, now_ms),
         {:ok, request_id} <- recovery_request_id(session),
         {:ok, lease} <- acquire_lease(request_id, opts) do
      {:ok, session |> Session.put_lease(lease) |> Session.bump_revision()}
    end
  end

  @doc false
  @spec checkpoint_transition(Session.t(), String.t(), AgentSnapshot.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def checkpoint_transition(%Session{} = session, lease_id, %AgentSnapshot{} = snapshot, opts) do
    now_ms = clock_ms(opts)

    with :ok <- validate_active_lease(session, lease_id, now_ms),
         :ok <- validate_checkpoint(session, snapshot) do
      lease = SessionLease.renew(session.lease, now_ms, lease_ttl_ms(opts))

      checkpointed =
        session
        |> Session.put_durable_checkpoint(snapshot)
        |> Session.put_lease(lease)
        |> Session.bump_revision()

      {:ok, checkpointed}
    end
  end

  @doc false
  @spec commit_transition(Session.t(), String.t(), Session.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def commit_transition(%Session{} = current, lease_id, %Session{} = completed, opts) do
    now_ms = clock_ms(opts)

    with :ok <- validate_active_lease(current, lease_id, now_ms),
         :ok <- validate_commit_target(current, completed) do
      committed =
        %Session{
          completed
          | revision: current.revision,
            lease: nil,
            requests: current.requests,
            snapshots: Session.merge_snapshots(current.snapshots, completed.snapshots),
            lineage: current.lineage
        }
        |> Session.bump_revision()

      {:ok, committed}
    end
  end

  @doc false
  @spec renew_transition(Session.t(), String.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def renew_transition(%Session{} = session, lease_id, opts) do
    now_ms = clock_ms(opts)

    with :ok <- validate_active_lease(session, lease_id, now_ms) do
      renewed =
        session
        |> Session.put_lease(SessionLease.renew(session.lease, now_ms, lease_ttl_ms(opts)))
        |> Session.bump_revision()

      {:ok, renewed}
    end
  end

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
         :ok <- ensure_claimable(session),
         session <- Session.put_request(session, request) do
      module.put_session(session, opts)
    end
  end

  defp ensure_claimable(%Session{status: :running, session_id: session_id}) do
    {:error, {:session_already_running, session_id}}
  end

  defp ensure_claimable(%Session{}), do: :ok

  defp ensure_resumable(%Session{status: status}) when status in [:hibernated, :waiting], do: :ok

  defp ensure_resumable(%Session{session_id: session_id, status: status}),
    do: {:error, {:session_not_resumable, session_id, status}}

  defp ensure_recoverable(%Session{status: status, session_id: session_id}, _now_ms)
       when status != :running,
       do: {:error, {:session_not_recoverable, session_id, status}}

  defp ensure_recoverable(%Session{lease: nil, session_id: session_id}, _now_ms),
    do: {:error, {:session_not_recoverable, session_id, :missing_lease}}

  defp ensure_recoverable(%Session{lease: %SessionLease{} = lease, session_id: session_id}, now_ms) do
    if SessionLease.expired?(lease, now_ms) do
      :ok
    else
      {:error, {:session_lease_active, session_id, lease.owner_id, lease.expires_at_ms}}
    end
  end

  defp validate_active_lease(
         %Session{lease: %SessionLease{lease_id: lease_id} = lease, session_id: session_id},
         lease_id,
         now_ms
       ) do
    if SessionLease.expired?(lease, now_ms) do
      {:error, {:session_lease_expired, session_id, lease_id, lease.expires_at_ms}}
    else
      :ok
    end
  end

  defp validate_active_lease(%Session{session_id: session_id}, lease_id, _now_ms),
    do: {:error, {:stale_session_lease, session_id, lease_id}}

  defp validate_checkpoint(
         %Session{agent_id: agent_id, lease: %SessionLease{request_id: request_id}},
         %AgentSnapshot{
           agent_id: agent_id,
           turn_state: %{request: %Turn.Request{request_id: request_id}}
         }
       ),
       do: :ok

  defp validate_checkpoint(%Session{session_id: session_id}, %AgentSnapshot{snapshot_id: snapshot_id}),
    do: {:error, {:checkpoint_session_mismatch, session_id, snapshot_id}}

  defp validate_commit_target(
         %Session{session_id: session_id, agent_id: agent_id},
         %Session{session_id: session_id, agent_id: agent_id}
       ),
       do: :ok

  defp validate_commit_target(%Session{} = current, %Session{} = completed),
    do: {:error, {:session_commit_mismatch, current.session_id, completed.session_id}}

  defp recoverable?(
         %Session{status: :running, lease: %SessionLease{} = lease} = session,
         now_ms
       ) do
    SessionLease.expired?(lease, now_ms) and match?({:ok, _request_id}, recovery_request_id(session))
  end

  defp recoverable?(_session, _now_ms), do: false

  defp recovery_request_id(%Session{} = session) do
    case Session.latest_snapshot(session) do
      %AgentSnapshot{turn_state: %{request: %Turn.Request{request_id: request_id}}} ->
        {:ok, request_id}

      nil ->
        case List.last(session.requests) do
          %Turn.Request{request_id: request_id} -> {:ok, request_id}
          nil -> {:error, {:session_not_recoverable, session.session_id, :missing_request}}
        end
    end
  end

  defp acquire_lease(request_id, opts) do
    SessionLease.acquire(request_id, clock_ms(opts), lease_ttl_ms(opts), opts)
  end

  defp lease_ttl_ms(opts) do
    case Keyword.get(opts, :lease_ttl_ms, @default_lease_ttl_ms) do
      ttl_ms when is_integer(ttl_ms) and ttl_ms > 0 -> ttl_ms
      ttl_ms -> raise ArgumentError, "lease_ttl_ms must be a positive integer, got: #{inspect(ttl_ms)}"
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
