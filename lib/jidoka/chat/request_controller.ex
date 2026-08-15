defmodule Jidoka.Chat.RequestController do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Jidoka.Cancellation
  alias Jidoka.Cancellation.Token
  alias Jidoka.Event
  alias Jidoka.Event.Order
  alias Jidoka.Runtime.EventDispatcher

  @task_supervisor Jidoka.Chat.TaskSupervisor
  @request_supervisor Jidoka.Chat.RequestSupervisor
  @stream_message_tag :jidoka_turn_event
  @default_grace_ms 100

  @type start_opts :: [
          request_id: String.t(),
          owner: pid(),
          target: term(),
          runtime_opts: keyword(),
          fun: (keyword() -> term())
        ]

  @spec start(start_opts()) :: {:ok, pid()} | {:error, term()}
  def start(opts) when is_list(opts) do
    DynamicSupervisor.start_child(@request_supervisor, {__MODULE__, opts})
  end

  @spec runtime(pid()) :: {:ok, Task.t(), Token.t()}
  def runtime(controller) when is_pid(controller), do: GenServer.call(controller, :runtime)

  @spec await(pid(), timeout()) :: term() | {:error, :timeout}
  def await(controller, timeout) when is_pid(controller) do
    GenServer.call(controller, :await, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, {:noproc, _call} -> {:error, :request_expired}
  end

  @spec cancel(pid(), keyword()) :: {:ok, Cancellation.t()} | {:error, term()}
  def cancel(controller, opts) when is_pid(controller) and is_list(opts) do
    grace_ms = positive_integer(Keyword.get(opts, :grace_ms), @default_grace_ms)
    timeout = positive_integer(Keyword.get(opts, :timeout), grace_ms + 5_000)
    GenServer.call(controller, {:cancel, grace_ms}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :cancellation_timeout}
    :exit, {:noproc, _call} -> {:error, :request_expired}
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    owner = Keyword.fetch!(opts, :owner)
    owner_monitor = Process.monitor(owner)
    runtime_opts = Keyword.fetch!(opts, :runtime_opts)
    fun = Keyword.fetch!(opts, :fun)
    token = Token.new()
    timeout_ms = positive_integer(Keyword.get(runtime_opts, :request_timeout_ms), nil)

    worker_opts =
      runtime_opts
      |> Keyword.put(:stream_to, self())
      |> Keyword.delete(:on_event)
      |> Keyword.delete(:on_cancelled)
      |> Keyword.put(:cancellation, token)

    task = Task.Supervisor.async_nolink(@task_supervisor, fn -> fun.(worker_opts) end)
    timeout_ref = if timeout_ms, do: Process.send_after(self(), :request_timeout, timeout_ms)

    {:ok,
     %{
       request_id: request_id,
       task: task,
       token: token,
       stream_to: Keyword.get(runtime_opts, :stream_to),
       on_event: Keyword.get(runtime_opts, :on_event),
       on_cancelled: Keyword.get(runtime_opts, :on_cancelled),
       owner: owner,
       owner_monitor: owner_monitor,
       status: :running,
       result: nil,
       terminal?: false,
       cancellation_requested?: false,
       cancellation_forced?: false,
       awaiters: [],
       cancellers: [],
       cancellation_members: %{},
       next_seq: 0,
       agent_id: nil,
       timeout_ref: timeout_ref
     }}
  end

  @impl true
  def handle_call(:runtime, _from, state) do
    {:reply, {:ok, state.task, state.token}, state}
  end

  def handle_call(:await, _from, %{status: :finished} = state) do
    {:reply, state.result, state}
  end

  def handle_call(:await, from, state) do
    {:noreply, %{state | awaiters: [from | state.awaiters]}}
  end

  def handle_call({:cancel, _grace_ms}, _from, %{terminal?: true} = state) do
    {:reply, {:error, :request_already_finished}, state}
  end

  def handle_call({:cancel, _grace_ms}, from, %{cancellation_requested?: true} = state) do
    {:noreply, %{state | cancellers: [from | state.cancellers]}}
  end

  def handle_call({:cancel, grace_ms}, from, state) do
    :ok = Token.request(state.token)
    Process.send_after(self(), {:force_cancel, state.task.ref}, grace_ms)

    {:noreply,
     %{
       state
       | cancellation_requested?: true,
         cancellers: [from | state.cancellers]
     }}
  end

  @impl true
  def handle_info({@stream_message_tag, %Event{} = event}, state) do
    {:noreply, accept_event(state, event)}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_from_worker(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, finish_from_exit(state, reason)}
  end

  def handle_info(
        {:DOWN, owner_monitor, :process, owner, _reason},
        %{owner: owner, owner_monitor: owner_monitor, status: :finished} = state
      ) do
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, owner_monitor, :process, owner, _reason},
        %{owner: owner, owner_monitor: owner_monitor} = state
      ) do
    _shutdown = Task.shutdown(state.task, :brutal_kill)
    {:stop, :normal, finish_race(state, {:error, :owner_exited})}
  end

  def handle_info(:request_timeout, %{status: :finished} = state), do: {:noreply, state}

  def handle_info(:request_timeout, state) do
    _shutdown = Task.shutdown(state.task, :brutal_kill)
    terminate_cancellation_members(state)
    {:noreply, finish_race(state, {:error, :request_timeout})}
  end

  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, state) do
    case Map.get(state.cancellation_members, pid) do
      ^monitor_ref ->
        {:noreply, %{state | cancellation_members: Map.delete(state.cancellation_members, pid)}}

      _monitor_ref ->
        {:noreply, state}
    end
  end

  def handle_info({:jidoka_cancellation_member, pid}, %{status: :finished} = state)
      when is_pid(pid) do
    Process.exit(pid, :kill)
    {:noreply, state}
  end

  def handle_info({:jidoka_cancellation_member, pid}, state) when is_pid(pid) do
    monitor_ref = Process.monitor(pid)

    {:noreply, %{state | cancellation_members: Map.put(state.cancellation_members, pid, monitor_ref)}}
  end

  def handle_info({:force_cancel, _ref}, %{status: :finished} = state), do: {:noreply, state}

  def handle_info({:force_cancel, ref}, %{task: %Task{ref: ref}} = state) do
    _shutdown = Task.shutdown(state.task, :brutal_kill)
    terminate_cancellation_members(state)
    {:noreply, finish_cancellation(%{state | cancellation_forced?: true})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.status == :running do
      _shutdown = Task.shutdown(state.task, :brutal_kill)
    end

    terminate_cancellation_members(state)
    :ok
  end

  defp accept_event(%{terminal?: true} = state, _event), do: state

  defp accept_event(state, %Event{} = event) do
    case Order.classify(event, state.request_id) do
      :accept -> accept_classified_event(state, event)
      {:reject, _reason} -> state
    end
  end

  defp accept_classified_event(%{cancellation_requested?: true} = state, %Event{} = event) do
    if EventDispatcher.terminal?(event) do
      state
      |> maybe_forward_cancel_event(event)
      |> Map.put(:terminal?, true)
    else
      forward_event(state, event)
    end
  end

  defp accept_classified_event(state, %Event{} = event) do
    state = forward_event(state, event)

    cond do
      Event.cancelled?(event) ->
        %{state | terminal?: true, cancellation_requested?: true}

      EventDispatcher.terminal?(event) ->
        %{state | terminal?: true}

      true ->
        state
    end
  end

  defp maybe_forward_cancel_event(state, %Event{} = event) do
    if Event.cancelled?(event) do
      forward_event(state, event)
    else
      emit_cancellation_event(state, state.cancellation_forced?)
    end
  end

  defp finish_from_worker(%{status: :finished} = state, _result), do: state

  defp finish_from_worker(%{cancellation_requested?: true} = state, _result) do
    finish_cancellation(state)
  end

  defp finish_from_worker(state, result) when is_tuple(result) do
    if Cancellation.cancelled_reason?(result) do
      finish_cancellation(%{state | cancellation_requested?: true})
    else
      finish_result(state, result)
    end
  end

  defp finish_from_worker(state, result) do
    finish_result(state, result)
  end

  defp finish_result(state, result) do
    state
    |> ensure_terminal_for_result(result)
    |> finish(result)
  end

  defp finish_from_exit(%{status: :finished} = state, _reason), do: state

  defp finish_from_exit(%{cancellation_requested?: true} = state, _reason) do
    finish_cancellation(state)
  end

  defp finish_from_exit(state, reason) do
    result = {:error, {:chat_request_failed, reason}}

    state
    |> ensure_terminal_for_result(result)
    |> finish(result)
  end

  defp finish_cancellation(state) do
    cancellation =
      Cancellation.new!(
        request_id: state.request_id,
        forced?: state.cancellation_forced?,
        cancelled_at_ms: System.system_time(:millisecond)
      )

    state =
      state
      |> ensure_cancellation_terminal()
      |> run_cancelled_callback(cancellation)

    Enum.each(state.cancellers, &GenServer.reply(&1, {:ok, cancellation}))
    finish(%{state | cancellers: []}, {:cancelled, cancellation})
  end

  defp finish_race(%{status: :finished} = state, _result), do: state

  defp finish_race(state, result) do
    state
    |> ensure_terminal_for_result(result)
    |> finish(result)
  end

  defp finish(state, result) do
    cancel_timeout(state)
    Enum.each(state.awaiters, &GenServer.reply(&1, result))
    Enum.each(state.cancellers, &GenServer.reply(&1, {:error, :request_already_finished}))

    %{state | status: :finished, result: result, awaiters: [], cancellers: []}
  end

  defp cancel_timeout(%{timeout_ref: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timeout(_state), do: false

  defp ensure_cancellation_terminal(%{terminal?: true} = state), do: state

  defp ensure_cancellation_terminal(state) do
    state
    |> emit_cancellation_event(state.cancellation_forced?)
    |> Map.put(:terminal?, true)
  end

  defp ensure_terminal_for_result(%{terminal?: true} = state, _result), do: state

  defp ensure_terminal_for_result(state, result) do
    event =
      Event.build(terminal_event(result), [],
        seq: state.next_seq,
        agent_id: state.agent_id,
        request_id: state.request_id,
        data: terminal_data(result)
      )

    state
    |> forward_event(event)
    |> Map.put(:terminal?, true)
  end

  defp terminal_event({:ok, _result}), do: :turn_finished
  defp terminal_event({:hibernate, _snapshot}), do: :turn_hibernated
  defp terminal_event({:hibernate, _session, _snapshot}), do: :turn_hibernated
  defp terminal_event(_result), do: :turn_failed

  defp terminal_data({:error, reason}), do: %{reason: inspect(reason)}
  defp terminal_data(_result), do: %{}

  defp emit_cancellation_event(state, forced?) do
    event =
      Event.build(:turn_failed, [],
        seq: state.next_seq,
        agent_id: state.agent_id,
        request_id: state.request_id,
        data: %{reason: :cancelled, forced: forced?}
      )

    forward_event(state, event)
  end

  defp forward_event(state, %Event{} = event) do
    event = %Event{event | seq: state.next_seq, request_id: state.request_id}

    :ok =
      EventDispatcher.emit(event,
        stream_to: state.stream_to,
        on_event: state.on_event,
        sequence: false
      )

    %{
      state
      | next_seq: max(state.next_seq, event.seq + 1),
        agent_id: event.agent_id || state.agent_id
    }
  end

  defp run_cancelled_callback(state, cancellation) do
    case state.on_cancelled do
      callback when is_function(callback, 1) ->
        _result = safe_callback(callback, cancellation)
        state

      _callback ->
        state
    end
  end

  defp safe_callback(callback, cancellation) do
    callback.(cancellation)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp terminate_cancellation_members(state) do
    Enum.each(Map.keys(state.cancellation_members), fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)
  end
end
