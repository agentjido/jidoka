defmodule Jidoka.Session.Transitions do
  @moduledoc """
  Pure durable session state transitions.

  This module validates revisions, leases, claims, checkpoints, commits, and
  recovery. It does not call a store or another external service. Custom
  durable stores use these public functions inside one backend transaction,
  persist the returned `Jidoka.Session.Data`, make that transaction durable,
  and only then send a successful callback reply.
  """

  alias Jidoka.Session.Data
  alias Jidoka.Session.Conversation
  alias Jidoka.Session.Lease
  alias Jidoka.Snapshot
  alias Jidoka.Turn

  @default_lease_ttl_ms 30_000

  @doc "Validates a direct session write against the current session."
  @spec put(Data.t() | nil, Data.t()) :: {:ok, Data.t()} | {:error, term()}
  def put(nil, %Data{} = incoming), do: {:ok, incoming}

  def put(%Data{lease: %Lease{}, session_id: session_id}, %Data{}) do
    {:error, {:session_lease_required, session_id}}
  end

  def put(
        %Data{session_id: session_id, revision: current_revision} = current,
        %Data{session_id: session_id, revision: incoming_revision} = incoming
      )
      when incoming_revision >= current_revision do
    with :ok <- validate_conversation_transition(current, incoming) do
      {:ok, incoming}
    end
  end

  def put(%Data{} = current, %Data{} = incoming) do
    {:error, {:stale_session_revision, current.session_id, incoming.session_id, current.revision, incoming.revision}}
  end

  @doc "Claims a session with a worker lease for one request."
  @spec claim(Data.t(), Turn.Request.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}
  def claim(%Data{} = session, %Turn.Request{} = request, opts) do
    with :ok <- ensure_claimable(session),
         :ok <- Conversation.validate_request_revision(session.conversation, request, session.session_id),
         {:ok, lease} <- acquire_lease(request.request_id, opts) do
      {:ok,
       session
       |> Data.put_request(request)
       |> Data.put_lease(lease)
       |> Data.bump_revision()}
    end
  end

  @doc "Claims a caller-managed session without a store lease."
  @spec claim_without_lease(Data.t(), Turn.Request.t()) :: {:ok, Data.t()} | {:error, term()}
  def claim_without_lease(%Data{} = session, %Turn.Request{} = request) do
    with :ok <- ensure_claimable(session),
         :ok <- Conversation.validate_request_revision(session.conversation, request, session.session_id) do
      {:ok, Data.put_request(session, request)}
    end
  end

  @doc "Claims a hibernated or waiting session for resume."
  @spec resume(Data.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}
  def resume(%Data{} = session, opts) do
    with {:ok, request_id} <- validate_resume(session),
         {:ok, lease} <- acquire_lease(request_id, opts) do
      {:ok, session |> Data.put_lease(lease) |> Data.bump_revision()}
    end
  end

  @doc false
  @spec resume_without_lease(Data.t()) :: {:ok, Data.t()} | {:error, term()}
  def resume_without_lease(%Data{} = session) do
    with {:ok, _request_id} <- validate_resume(session) do
      {:ok, session}
    end
  end

  @doc "Replaces an expired lease for crash recovery."
  @spec recover(Data.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}
  def recover(%Data{} = session, opts) do
    now_ms = clock_ms(opts)

    with :ok <- ensure_recoverable(session, now_ms),
         {:ok, target} <- Data.recovery_target(session),
         request_id = recovery_request_id(target),
         {:ok, lease} <- acquire_lease(request_id, opts) do
      {:ok, session |> Data.put_lease(lease) |> Data.bump_revision()}
    end
  end

  @doc "Records a durable snapshot under an active lease."
  @spec checkpoint(Data.t(), String.t(), Snapshot.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def checkpoint(%Data{} = session, lease_id, %Snapshot{} = snapshot, opts) do
    now_ms = clock_ms(opts)

    with :ok <- validate_active_lease(session, lease_id, now_ms),
         :ok <- validate_checkpoint(session, snapshot) do
      lease = Lease.renew(session.lease, now_ms, lease_ttl_ms(opts))

      {:ok,
       session
       |> Data.put_durable_checkpoint(snapshot)
       |> Data.put_lease(lease)
       |> Data.bump_revision()}
    end
  end

  @doc "Commits session state and releases its active lease."
  @spec commit(Data.t(), String.t(), Data.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def commit(%Data{} = current, lease_id, %Data{} = completed, opts) do
    now_ms = clock_ms(opts)

    with :ok <- validate_active_lease(current, lease_id, now_ms),
         :ok <- validate_commit_target(current, completed),
         :ok <- validate_conversation_transition(current, completed) do
      committed =
        %Data{
          completed
          | revision: current.revision,
            lease: nil,
            requests: current.requests,
            snapshots: Data.merge_snapshots(current.snapshots, completed.snapshots),
            environment: merge_environment(current.environment, completed.environment),
            lineage: current.lineage
        }
        |> Data.bump_revision()

      {:ok, committed}
    end
  end

  @doc "Extends an active session lease."
  @spec renew(Data.t(), String.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}
  def renew(%Data{} = session, lease_id, opts) do
    now_ms = clock_ms(opts)

    with :ok <- validate_active_lease(session, lease_id, now_ms) do
      {:ok,
       session
       |> Data.put_lease(Lease.renew(session.lease, now_ms, lease_ttl_ms(opts)))
       |> Data.bump_revision()}
    end
  end

  @doc "Returns true when a running session has recoverable expired work."
  @spec recoverable?(Data.t(), non_neg_integer()) :: boolean()
  def recoverable?(%Data{status: :running, lease: %Lease{} = lease} = session, now_ms) do
    Lease.expired?(lease, now_ms) and match?({:ok, _target}, Data.recovery_target(session))
  end

  def recoverable?(_session, _now_ms), do: false

  defp ensure_claimable(%Data{status: :running, session_id: session_id}),
    do: {:error, {:session_already_running, session_id}}

  defp ensure_claimable(%Data{}), do: :ok

  defp ensure_resumable(%Data{status: status}) when status in [:hibernated, :waiting], do: :ok

  defp ensure_resumable(%Data{session_id: session_id, status: status}),
    do: {:error, {:session_not_resumable, session_id, status}}

  defp ensure_recoverable(%Data{status: status, session_id: session_id}, _now_ms)
       when status != :running,
       do: {:error, {:session_not_recoverable, session_id, status}}

  defp ensure_recoverable(%Data{lease: nil, session_id: session_id}, _now_ms),
    do: {:error, {:session_not_recoverable, session_id, :missing_lease}}

  defp ensure_recoverable(%Data{lease: %Lease{} = lease, session_id: session_id}, now_ms) do
    if Lease.expired?(lease, now_ms),
      do: :ok,
      else: {:error, {:session_lease_active, session_id, lease.owner_id, lease.expires_at_ms}}
  end

  defp validate_resume(%Data{} = session) do
    with :ok <- ensure_resumable(session),
         %Snapshot{turn_state: %{request: %Turn.Request{request_id: request_id}}} = snapshot <-
           Data.latest_snapshot(session),
         :ok <- Conversation.validate_snapshot_revision(session.conversation, snapshot, session.session_id) do
      {:ok, request_id}
    else
      nil -> {:error, {:missing_session_snapshot, session.session_id}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_active_lease(
         %Data{lease: %Lease{lease_id: lease_id} = lease, session_id: session_id},
         lease_id,
         now_ms
       ) do
    if Lease.expired?(lease, now_ms),
      do: {:error, {:session_lease_expired, session_id, lease_id, lease.expires_at_ms}},
      else: :ok
  end

  defp validate_active_lease(%Data{session_id: session_id}, lease_id, _now_ms),
    do: {:error, {:stale_session_lease, session_id, lease_id}}

  defp validate_checkpoint(
         %Data{
           agent_id: agent_id,
           session_id: session_id,
           conversation: conversation,
           lease: %Lease{request_id: request_id}
         },
         %Snapshot{
           agent_id: agent_id,
           turn_state: %{request: %Turn.Request{request_id: request_id}}
         } = snapshot
       ),
       do: Conversation.validate_snapshot_revision(conversation, snapshot, session_id)

  defp validate_checkpoint(%Data{session_id: session_id}, %Snapshot{snapshot_id: snapshot_id}),
    do: {:error, {:checkpoint_session_mismatch, session_id, snapshot_id}}

  defp validate_commit_target(
         %Data{session_id: session_id, agent_id: agent_id},
         %Data{session_id: session_id, agent_id: agent_id}
       ),
       do: :ok

  defp validate_commit_target(%Data{} = current, %Data{} = completed),
    do: {:error, {:session_commit_mismatch, current.session_id, completed.session_id}}

  defp validate_conversation_transition(
         %Data{conversation: current},
         %Data{conversation: incoming}
       )
       when incoming.continuation_revision == current.continuation_revision,
       do: :ok

  defp validate_conversation_transition(
         %Data{session_id: session_id, conversation: current},
         %Data{status: :finished, conversation: incoming, requests: requests}
       ) do
    expected = Conversation.next_revision(current, List.last(requests))

    if incoming.continuation_revision == expected,
      do: :ok,
      else:
        {:error,
         {:invalid_conversation_commit_revision, session_id, current.continuation_revision,
          incoming.continuation_revision, expected}}
  end

  defp validate_conversation_transition(
         %Data{session_id: session_id, conversation: current},
         %Data{conversation: incoming}
       ) do
    {:error,
     {:invalid_conversation_commit_revision, session_id, current.continuation_revision, incoming.continuation_revision,
      current.continuation_revision}}
  end

  defp merge_environment(nil, completed), do: completed
  defp merge_environment(current, nil), do: current

  defp merge_environment(
         %{binding: %{revision: current_revision}} = current,
         %{binding: %{revision: completed_revision}}
       )
       when current_revision > completed_revision,
       do: current

  defp merge_environment(_current, completed), do: completed

  defp recovery_request_id({:resume, %Snapshot{turn_state: %{request: %Turn.Request{request_id: request_id}}}}),
    do: request_id

  defp recovery_request_id({:restart, %Turn.Request{request_id: request_id}}), do: request_id

  defp acquire_lease(request_id, opts) do
    Lease.acquire(request_id, clock_ms(opts), lease_ttl_ms(opts), opts)
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
end
