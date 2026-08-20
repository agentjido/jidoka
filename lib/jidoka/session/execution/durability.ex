defmodule Jidoka.Session.Execution.Durability do
  @moduledoc false

  alias Jidoka.Cancellation
  alias Jidoka.Session.Data, as: Session
  alias Jidoka.Session.EnvironmentRuntime
  alias Jidoka.Session.Lease
  alias Jidoka.Session.LeaseHeartbeat
  alias Jidoka.Session.Store
  alias Jidoka.Snapshot
  alias Jidoka.Turn

  @spec runtime_opts(Session.t(), keyword()) :: keyword()
  def runtime_opts(%Session{lease: %Lease{} = lease} = session, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} ->
        opts = Keyword.put_new(opts, :cancellation, Cancellation.Token.new())

        checkpoint = fn state, intent, stage ->
          durable_checkpoint(store, session, lease, state, intent, stage, opts)
        end

        Keyword.put(opts, :durable_checkpoint, checkpoint)

      :error ->
        opts
    end
  end

  def runtime_opts(%Session{}, opts), do: opts

  @spec start_heartbeat(Session.t(), keyword()) :: {:ok, pid() | nil} | {:error, term()}
  def start_heartbeat(
        %Session{lease: %Lease{lease_id: lease_id}, session_id: session_id},
        opts
      ) do
    cond do
      not Keyword.has_key?(opts, :store) ->
        {:ok, nil}

      Keyword.get(opts, :lease_heartbeat, true) == false ->
        {:ok, nil}

      true ->
        LeaseHeartbeat.start_link(Keyword.fetch!(opts, :store), session_id, lease_id, opts)
    end
  end

  def start_heartbeat(%Session{}, _opts), do: {:ok, nil}

  @spec stop_heartbeat(pid() | nil) :: :ok
  def stop_heartbeat(nil), do: :ok

  def stop_heartbeat(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  end

  @spec store_opts(keyword()) :: keyword()
  def store_opts(opts) do
    Keyword.take(opts, [:clock, :id_generator, :lease_ttl_ms, :owner_id])
  end

  defp durable_checkpoint(store, session, lease, state, intent, stage, opts) do
    cursor = Turn.Cursor.before_effect(intent)

    with {:ok, environment} <- EnvironmentRuntime.checkpoint(opts),
         {:ok, snapshot} <-
           Snapshot.from_turn_state(state, cursor,
             id_generator: Keyword.get(opts, :id_generator),
             environment: environment,
             metadata: %{"durable_checkpoint" => Atom.to_string(stage)}
           ),
         {:ok, stored} <-
           Store.checkpoint_session(
             store,
             session.session_id,
             lease.lease_id,
             snapshot,
             store_opts(opts)
           ) do
      run_checkpoint_hook(stage, snapshot, stored, opts)
    end
  end

  defp run_checkpoint_hook(stage, snapshot, stored, opts) do
    case Keyword.get(opts, :on_durable_checkpoint) do
      hook when is_function(hook, 3) -> hook.(stage, snapshot, stored)
      _hook -> :ok
    end
  end
end
