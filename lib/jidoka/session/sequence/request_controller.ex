defmodule Jidoka.Session.Sequence.RequestController do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Jidoka.Cancellation
  alias Jidoka.Cancellation.Token
  alias Jidoka.Session.Data
  alias Jidoka.Session.Execution
  alias Jidoka.Session.Sequence
  alias Jidoka.Turn

  @task_supervisor Jidoka.Session.Sequence.TaskSupervisor
  @request_supervisor Jidoka.Session.Sequence.RequestSupervisor
  @default_grace_ms 100
  @default_retention_ms 30_000

  @type start_opts :: [
          request_id: String.t(),
          owner: pid(),
          session_input: Data.t() | String.t(),
          session: Data.t(),
          request_inputs: Sequence.input(),
          runtime_opts: keyword()
        ]

  @doc false
  @spec start(start_opts()) :: {:ok, pid()} | {:error, term()}
  def start(opts) when is_list(opts) do
    DynamicSupervisor.start_child(@request_supervisor, {__MODULE__, opts})
  end

  @doc false
  @spec await(pid(), timeout()) :: term() | {:error, :timeout | :request_expired}
  def await(controller, timeout) when is_pid(controller) do
    GenServer.call(controller, :await, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, {:noproc, _call} -> {:error, :request_expired}
  end

  @doc false
  @spec cancel(pid(), keyword()) :: {:ok, Cancellation.t()} | {:error, term()}
  def cancel(controller, opts) when is_pid(controller) and is_list(opts) do
    grace_ms = positive_integer(Keyword.get(opts, :grace_ms), @default_grace_ms)
    timeout = positive_integer(Keyword.get(opts, :timeout), grace_ms + 5_000)
    GenServer.call(controller, {:cancel, grace_ms}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :cancellation_timeout}
    :exit, {:noproc, _call} -> {:error, :request_expired}
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    owner = Keyword.fetch!(opts, :owner)
    owner_monitor = Process.monitor(owner)
    session_input = Keyword.fetch!(opts, :session_input)
    session = Keyword.fetch!(opts, :session)
    request_inputs = Keyword.fetch!(opts, :request_inputs)
    runtime_opts = Keyword.fetch!(opts, :runtime_opts)
    retention_ms = positive_integer(Keyword.get(runtime_opts, :request_retention_ms), @default_retention_ms)
    token = Token.new()
    controller = self()

    progress = fn progress ->
      send(controller, {:sequence_progress, request_id, progress})
      :ok
    end

    worker_opts =
      runtime_opts
      |> Keyword.put(:cancellation, token)
      |> Keyword.put(:sequence_progress, progress)

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        Execution.run_sequence(session_input, request_inputs, worker_opts)
      end)

    {:ok,
     %{
       request_id: request_id,
       task: task,
       token: token,
       owner: owner,
       owner_monitor: owner_monitor,
       runtime_opts: runtime_opts,
       status: :running,
       result: nil,
       cancellation_requested?: false,
       cancellation_forced?: false,
       awaiters: [],
       cancellers: [],
       cancellation_members: %{},
       progress: %{session: session, steps: [], index: 1, request: nil},
       retention_ms: retention_ms,
       expiry_ref: nil
     }}
  end

  @impl true
  def handle_call(:await, _from, %{status: :finished} = state) do
    {:reply, state.result, state}
  end

  def handle_call(:await, from, state) do
    {:noreply, %{state | awaiters: [from | state.awaiters]}}
  end

  def handle_call({:cancel, _grace_ms}, _from, %{status: :finished} = state) do
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
  def handle_info({:sequence_progress, request_id, progress}, %{request_id: request_id} = state) do
    {:noreply, %{state | progress: progress}}
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
        %{owner: owner, owner_monitor: owner_monitor} = state
      ) do
    {:stop, :normal, state}
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

  def handle_info({:expire_request, expiry_ref}, %{status: :finished, expiry_ref: expiry_ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:force_cancel, _ref}, %{status: :finished} = state), do: {:noreply, state}

  def handle_info({:force_cancel, ref}, %{task: %Task{ref: ref}} = state) do
    _shutdown = Task.shutdown(state.task, :brutal_kill)
    terminate_cancellation_members(state)
    {:noreply, finish_cancellation(%{state | cancellation_forced?: true}, nil)}
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

  defp finish_from_worker(%{status: :finished} = state, _result), do: state

  defp finish_from_worker(%{cancellation_requested?: true} = state, {:ok, %Sequence.Result{} = result}) do
    if result.status in [:completed, :hibernated] do
      finish_terminal_winner(state, {:ok, result})
    else
      finish_cancellation(state, result)
    end
  end

  defp finish_from_worker(%{cancellation_requested?: true} = state, _result) do
    finish_cancellation(state, nil)
  end

  defp finish_from_worker(state, result), do: finish(state, result)

  defp finish_from_exit(%{status: :finished} = state, _reason), do: state

  defp finish_from_exit(%{cancellation_requested?: true} = state, _reason) do
    finish_cancellation(state, nil)
  end

  defp finish_from_exit(state, reason) do
    finish(state, {:error, {:session_sequence_request_failed, reason}})
  end

  defp finish_terminal_winner(state, result) do
    Enum.each(state.cancellers, &GenServer.reply(&1, {:error, :request_already_finished}))
    finish(%{state | cancellers: []}, result)
  end

  defp finish_cancellation(state, result) do
    cancellation =
      Cancellation.new!(
        request_id: state.request_id,
        forced?: state.cancellation_forced?,
        cancelled_at_ms: System.system_time(:millisecond)
      )

    progress = progress_for_result(state.progress, result)
    session = persist_cancellation(progress, cancellation, state.runtime_opts)
    sequence = cancelled_result(progress, session, cancellation, result)

    Enum.each(state.cancellers, &GenServer.reply(&1, {:ok, cancellation}))
    finish(%{state | cancellers: []}, {:cancelled, cancellation, sequence})
  end

  defp progress_for_result(progress, %Sequence.Result{} = result) do
    terminal = result.terminal

    %{
      progress
      | session: result.session,
        steps: result.steps,
        index: if(terminal, do: terminal.index, else: progress.index)
    }
  end

  defp progress_for_result(progress, _result), do: progress

  defp persist_cancellation(progress, cancellation, opts) do
    case Execution.persist_sequence_cancellation(progress, cancellation, opts) do
      {:ok, %Data{} = session} -> session
      {:error, _reason} -> local_cancelled_session(progress, cancellation)
    end
  end

  defp local_cancelled_session(%{session: session, request: request}, cancellation) do
    session
    |> maybe_put_request(request)
    |> Data.put_cancellation(cancellation)
    |> Data.clear_lease()
  end

  defp maybe_put_request(session, %Turn.Request{request_id: request_id} = request) do
    case List.last(session.requests) do
      %Turn.Request{request_id: ^request_id} -> session
      _last -> Data.put_request(session, request)
    end
  end

  defp maybe_put_request(session, _request), do: session

  defp cancelled_result(progress, session, cancellation, %Sequence.Result{} = result) do
    terminal = result.terminal

    build_cancelled_result(
      session,
      result.steps,
      if(terminal, do: terminal.index, else: progress.index),
      terminal_request_id(terminal, progress),
      cancellation,
      result.limits
    )
  end

  defp cancelled_result(progress, session, cancellation, _result) do
    build_cancelled_result(
      session,
      progress.steps,
      progress.index,
      request_id(progress.request),
      cancellation,
      nil
    )
  end

  defp build_cancelled_result(session, steps, index, request_id, cancellation, limits) do
    terminal =
      Sequence.Terminal.new!(
        kind: :cancelled,
        index: index,
        request_id: request_id,
        reason: cancellation,
        snapshot: nil,
        cancellation: cancellation
      )

    Sequence.Result.new!(
      status: :cancelled,
      session: session,
      steps: steps,
      terminal: terminal,
      limits: limits
    )
  end

  defp terminal_request_id(%Sequence.Terminal{request_id: request_id}, _progress),
    do: request_id

  defp terminal_request_id(_terminal, progress), do: request_id(progress.request)

  defp request_id(%Turn.Request{request_id: request_id}), do: request_id
  defp request_id(_request), do: nil

  defp finish(%{status: :finished} = state, _result), do: state

  defp finish(state, result) do
    terminate_cancellation_members(state)
    Enum.each(state.awaiters, &GenServer.reply(&1, result))
    expiry_ref = make_ref()
    Process.send_after(self(), {:expire_request, expiry_ref}, state.retention_ms)

    %{state | status: :finished, result: result, awaiters: [], expiry_ref: expiry_ref}
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp terminate_cancellation_members(state) do
    Enum.each(Map.keys(state.cancellation_members), fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)
  end
end
