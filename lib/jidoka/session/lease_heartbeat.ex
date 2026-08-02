defmodule Jidoka.Session.LeaseHeartbeat do
  @moduledoc false

  use GenServer

  alias Jidoka.Cancellation
  alias Jidoka.Session.Store

  @spec start_link(Store.store(), String.t(), String.t(), keyword()) :: GenServer.on_start()
  def start_link(store, session_id, lease_id, opts) do
    GenServer.start_link(__MODULE__, {store, session_id, lease_id, self(), opts})
  end

  @impl true
  def init({store, session_id, lease_id, owner, opts}) do
    state = %{
      store: store,
      session_id: session_id,
      lease_id: lease_id,
      owner: owner,
      cancellation: Keyword.get(opts, :cancellation),
      interval_ms: heartbeat_interval_ms(opts),
      runtime_opts: Keyword.take(opts, [:clock, :lease_ttl_ms])
    }

    schedule_renewal(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:renew, state) do
    case Store.renew_session(
           state.store,
           state.session_id,
           state.lease_id,
           state.runtime_opts
         ) do
      {:ok, _session} ->
        schedule_renewal(state.interval_ms)
        {:noreply, state}

      {:error, reason} ->
        unless lease_released?(state) do
          request_cancellation(state.cancellation)
          send(state.owner, {:jidoka_session_lease_lost, state.session_id, state.lease_id, reason})
        end

        {:stop, :normal, state}
    end
  end

  defp request_cancellation(%Cancellation.Token{} = token), do: Cancellation.Token.request(token)
  defp request_cancellation(_token), do: :ok

  defp lease_released?(state) do
    case Store.get_session(state.store, state.session_id) do
      {:ok, %{status: status, lease: nil}} when status != :running -> true
      _result -> false
    end
  end

  defp schedule_renewal(interval_ms), do: Process.send_after(self(), :renew, interval_ms)

  defp heartbeat_interval_ms(opts) do
    ttl_ms = Keyword.get(opts, :lease_ttl_ms, 30_000)
    default = max(div(ttl_ms, 3), 1)

    case Keyword.get(opts, :lease_heartbeat_interval_ms, default) do
      interval_ms when is_integer(interval_ms) and interval_ms > 0 -> interval_ms
      _interval_ms -> default
    end
  end
end
