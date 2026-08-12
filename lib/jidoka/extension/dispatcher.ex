defmodule Jidoka.Extension.Dispatcher do
  @moduledoc "Ordered failure-isolated delivery of extension lifecycle events."

  use GenServer

  alias Jidoka.Extension.Event

  @type subscriber :: (Event.t() -> term()) | module()

  @doc "Starts a dispatcher with ordered subscribers."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Delivers one immutable event in session order. Subscriber failures are evidence only."
  @spec dispatch(GenServer.server(), Event.t(), keyword()) :: {:ok, [map()]}
  def dispatch(dispatcher, %Event{} = event, opts \\ []) do
    GenServer.call(dispatcher, {:dispatch, event, opts}, Keyword.get(opts, :call_timeout, 30_000))
  end

  @impl true
  def init(opts) do
    {:ok, %{subscribers: Keyword.get(opts, :subscribers, []), timeout_ms: Keyword.get(opts, :timeout_ms, 100)}}
  end

  @impl true
  def handle_call({:dispatch, event, opts}, _from, state) do
    timeout = Keyword.get(opts, :subscriber_timeout_ms, state.timeout_ms)
    evidence = Enum.map(state.subscribers, &deliver(&1, event, timeout))
    {:reply, {:ok, evidence}, state}
  end

  defp deliver(subscriber, event, timeout) do
    owner = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        result = safe_invoke(subscriber, event)
        send(owner, {:extension_subscriber_result, owner, self(), result})
      end)

    receive do
      {:extension_subscriber_result, ^owner, ^pid, result} ->
        Process.demonitor(monitor, [:flush])
        delivery_result(result)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        %{"status" => "failed", "reason" => inspect(reason)}
    after
      timeout ->
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^monitor, :process, ^pid, _reason} -> :ok)
        %{"status" => "timeout"}
    end
  end

  defp delivery_result(:ok), do: %{"status" => "delivered"}
  defp delivery_result({:ok, _value}), do: %{"status" => "delivered"}
  defp delivery_result({:subscriber_failed, reason}), do: %{"status" => "failed", "reason" => inspect(reason)}
  defp delivery_result(other), do: %{"status" => "malformed_return", "result" => inspect(other)}

  defp safe_invoke(subscriber, event) do
    invoke(subscriber, event)
  rescue
    exception -> {:subscriber_failed, exception}
  catch
    kind, reason -> {:subscriber_failed, {kind, reason}}
  end

  defp invoke(subscriber, event) when is_function(subscriber, 1), do: subscriber.(event)

  defp invoke(subscriber, event) when is_atom(subscriber) do
    if function_exported?(subscriber, :handle_event, 1),
      do: subscriber.handle_event(event),
      else: {:error, :invalid_subscriber}
  end

  defp invoke(_subscriber, _event), do: {:error, :invalid_subscriber}
end
