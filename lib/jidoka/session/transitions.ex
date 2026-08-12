defmodule Jidoka.Session.Transitions do
  @moduledoc """
  Pure durable session state transitions.

  This module validates revisions, leases, claims, checkpoints, commits, and
  recovery. It does not call a store or another external service.
  """

  alias Jidoka.Session.Data
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
        %Data{session_id: session_id, revision: current_revision},
        %Data{session_id: session_id, revision: incoming_revision} = incoming
      )
      when incoming_revision >= current_revision,
      do: {:ok, incoming}

  def put(%Data{} = current, %Data{} = incoming) do
    {:error, {:stale_session_revision, current.session_id, incoming.session_id, current.revision, incoming.revision}}
  end

  @doc "Claims a session with a worker lease for one request."
  @spec claim(Data.t(), Turn.Request.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}
  def claim(%Data{} = session, %Turn.Request{} = request, opts) do
    with :ok <- ensure_claimable(session),
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
    with :ok <- ensure_claimable(session), do: {:ok, Data.put_request(session, request)}
  end

  @doc "Claims a hibernated or waiting session for resume."
  @spec resume(Data.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}
  def resume(%Data{} = session, opts) do
    with :ok <- ensure_resumable(session),
         %Snapshot{turn_state: %{request: %Turn.Request{request_id: request_id}}} <-
           Data.latest_snapshot(session),
         {:ok, lease} <- acquire_lease(request_id, opts) do
      {:ok, session |> Data.put_lease(lease) |> Data.bump_revision()}
    else
      nil -> {:error, {:missing_session_snapshot, session.session_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Replaces an expired lease for crash recovery."
  @spec recover(Data.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}
  def recover(%Data{} = session, opts) do
    now_ms = clock_ms(opts)

    with :ok <- ensure_recoverable(session, now_ms),
         {:ok, request_id} <- recovery_request_id(session),
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
         :ok <- validate_commit_target(current, completed) do
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
    Lease.expired?(lease, now_ms) and match?({:ok, _request_id}, recovery_request_id(session))
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
         %Data{agent_id: agent_id, lease: %Lease{request_id: request_id}},
         %Snapshot{
           agent_id: agent_id,
           turn_state: %{request: %Turn.Request{request_id: request_id}}
         }
       ),
       do: :ok

  defp validate_checkpoint(%Data{session_id: session_id}, %Snapshot{snapshot_id: snapshot_id}),
    do: {:error, {:checkpoint_session_mismatch, session_id, snapshot_id}}

  defp validate_commit_target(
         %Data{session_id: session_id, agent_id: agent_id},
         %Data{session_id: session_id, agent_id: agent_id}
       ),
       do: :ok

  defp validate_commit_target(%Data{} = current, %Data{} = completed),
    do: {:error, {:session_commit_mismatch, current.session_id, completed.session_id}}

  defp merge_environment(nil, completed), do: completed
  defp merge_environment(current, nil), do: current

  defp merge_environment(
         %{binding: %{revision: current_revision}} = current,
         %{binding: %{revision: completed_revision}}
       )
       when current_revision > completed_revision,
       do: current

  defp merge_environment(_current, completed), do: completed

  defp recovery_request_id(%Data{} = session) do
    case Data.latest_snapshot(session) do
      %Snapshot{turn_state: %{request: %Turn.Request{request_id: request_id}}} ->
        {:ok, request_id}

      nil ->
        case List.last(session.requests) do
          %Turn.Request{request_id: request_id} -> {:ok, request_id}
          nil -> {:error, {:session_not_recoverable, session.session_id, :missing_request}}
        end
    end
  end

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
