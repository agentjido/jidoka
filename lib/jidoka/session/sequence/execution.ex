defmodule Jidoka.Session.Sequence.Execution do
  @moduledoc false

  alias Jidoka.Cancellation
  alias Jidoka.Session.Data, as: Session
  alias Jidoka.Session.EnvironmentRuntime
  alias Jidoka.Session.Lease
  alias Jidoka.Session.Sequence
  alias Jidoka.Session.Store
  alias Jidoka.Runtime.Limits
  alias Jidoka.Snapshot
  alias Jidoka.Turn
  alias Jidoka.Turn.Execution, as: TurnExecution

  @type session_input :: Session.t() | String.t()
  @type runner :: (session_input(), Turn.Request.t(), keyword() -> term())

  @doc false
  @spec run(session_input(), Sequence.input(), keyword(), runner()) ::
          {:ok, Sequence.Result.t()} | {:error, term()}
  def run(session_input, request_inputs, opts, runner)

  def run(session_input, [_request | _rest] = request_inputs, opts, runner)
      when is_list(request_inputs) and is_list(opts) and is_function(runner, 3) do
    EnvironmentRuntime.with_manager(opts, fn runtime_opts ->
      run_with_runtime(session_input, request_inputs, runtime_opts, runner)
    end)
  end

  def run(_session_input, [], opts, runner) when is_list(opts) and is_function(runner, 3),
    do: {:error, :empty_session_sequence}

  def run(_session_input, request_inputs, opts, runner) when is_list(opts) and is_function(runner, 3),
    do: {:error, {:invalid_session_sequence, request_inputs}}

  @doc false
  @spec resolve_session(session_input(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def resolve_session(%Session{} = session, _opts), do: {:ok, session}

  def resolve_session(session_id, opts) when is_binary(session_id) and is_list(opts) do
    with {:ok, store} <- fetch_store(opts), do: Store.get_session(store, session_id)
  end

  @doc false
  @spec persist_cancellation(map(), Cancellation.t(), keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def persist_cancellation(progress, %Cancellation{} = cancellation, opts)
      when is_map(progress) and is_list(opts) do
    with {:ok, session} <- cancellation_session(progress, opts) do
      cancelled =
        session
        |> maybe_put_request(Map.get(progress, :request))
        |> Session.put_cancellation(cancellation)

      persist_cancelled_session(cancelled, opts)
    end
  end

  defp run_with_runtime(session_input, request_inputs, opts, runner) do
    with :ok <- validate_store_mode(opts),
         {:ok, session} <- resolve_session(session_input, opts),
         {:ok, plan} <- TurnExecution.plan(session.spec),
         {:ok, limits} <- Limits.resolve(plan, opts) do
      opts =
        opts
        |> Keyword.put(:runtime_limits, limits)
        |> Keyword.put(:runtime_sequence_started_at_ms, runtime_clock_ms(opts))

      Jidoka.Extension.RuntimeEvents.emit(
        "session.start",
        %{session_ref: session.session_id, data: %{request_count: length(request_inputs)}},
        opts
      )

      with_environment_observer(session, opts, fn runtime_opts ->
        state = %{
          session: session,
          steps: [],
          operation_count: operation_count(session, opts),
          request_ids: []
        }

        result =
          request_inputs
          |> run_steps(state, 1, runtime_opts, runner)
          |> put_limits(limits, runtime_opts)

        Jidoka.Extension.RuntimeEvents.emit(
          "session.end",
          %{session_ref: session.session_id, data: %{status: result.status}},
          opts
        )

        result
      end)
    end
  end

  defp with_environment_observer(session, opts, run) do
    {:ok, tracker} = Elixir.Agent.start_link(fn -> session.environment end)
    observer = fn environment -> Elixir.Agent.update(tracker, fn _current -> environment end) end
    runtime_opts = Keyword.put(opts, :session_environment_observer, observer)

    try do
      result = run.(runtime_opts)

      case Elixir.Agent.get(tracker, & &1) do
        nil -> {:ok, result}
        environment -> {:ok, put_environment(result, environment)}
      end
    after
      Elixir.Agent.stop(tracker)
    end
  end

  defp put_environment(%Sequence.Result{} = result, environment) do
    %{result | session: Session.put_environment(result.session, environment)}
  end

  defp run_steps([], state, _index, _opts, _runner) do
    Sequence.Result.new!(status: :completed, session: state.session, steps: state.steps, terminal: nil)
  end

  defp run_steps([input | rest], state, index, opts, runner) do
    with {:ok, request} <- normalize_request(input, opts),
         :ok <- ensure_unique_request(request, state.request_ids, index) do
      notify_progress(state, index, request, opts)

      case Limits.check_sequence_deadline(opts, index) do
        :ok -> run_after_deadline(state, request, rest, index, opts, runner)
        {:error, exceeded} -> run_error(state, request, {:runtime_limit_exceeded, exceeded}, index, opts)
      end
    else
      {:error, reason} ->
        terminal_result(:error, state.session, state.steps, index, request_id(input), nil, reason)
    end
  end

  defp run_after_deadline(state, request, rest, index, opts, runner) do
    case Cancellation.check(opts) do
      :ok -> run_request(state, request, rest, index, opts, runner)
      {:error, reason} -> run_error(state, request, reason, index, opts)
    end
  end

  defp run_request(state, request, rest, index, opts, runner) do
    run_opts =
      opts
      |> Keyword.put(:session_sequence_active, true)
      |> Keyword.put(:session_sequence_terminal, rest == [])
      |> Keyword.put(:fresh_conversation, index == 1 and Keyword.get(opts, :fresh_conversation, false))

    case runner.(session_input(state.session, opts), request, run_opts) do
      {:ok, session, %Turn.Result{} = result} ->
        continue_after_result(state, request, rest, index, opts, runner, session, result)

      {:hibernate, session, %Snapshot{} = snapshot} ->
        terminal_result(:hibernated, session, state.steps, index, request.request_id, snapshot, nil)

      {:error, session, reason} ->
        run_error(%{state | session: session}, request, reason, index, opts)

      {:error, reason} ->
        run_error(state, request, reason, index, opts)
    end
  end

  defp continue_after_result(state, request, rest, index, opts, runner, session, result) do
    operation_results = Enum.drop(result.agent_state.operation_results, state.operation_count)

    step =
      Sequence.Step.new!(
        index: index,
        request: request,
        result: result,
        operation_results: operation_results
      )

    next_state = %{
      session: session,
      steps: state.steps ++ [step],
      operation_count: length(result.agent_state.operation_results),
      request_ids: [request.request_id | state.request_ids]
    }

    case check_usage(next_state.steps, rest, opts, index) do
      :ok -> run_steps(rest, next_state, index + 1, opts, runner)
      {:error, exceeded} -> run_error(next_state, request, {:runtime_limit_exceeded, exceeded}, index, opts)
    end
  end

  defp check_usage(steps, [], opts, index),
    do: Limits.check_usage(steps, Keyword.fetch!(opts, :runtime_limits), index)

  defp check_usage(steps, _rest, opts, index),
    do: Limits.check_usage_before_next(steps, Keyword.fetch!(opts, :runtime_limits), index)

  defp notify_progress(state, index, request, opts) do
    case Keyword.get(opts, :sequence_progress) do
      callback when is_function(callback, 1) ->
        _result = safe_progress(callback, %{session: state.session, steps: state.steps, index: index, request: request})
        :ok

      _callback ->
        :ok
    end
  end

  defp safe_progress(callback, progress) do
    callback.(progress)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp normalize_request(input, opts), do: Turn.Request.from_input(input, Keyword.take(opts, [:id_generator]))

  defp run_error(state, request, reason, index, opts) do
    status = if Cancellation.cancelled_reason?(reason), do: :cancelled, else: :error
    session = error_session(state.session, request, status, reason, opts)
    terminal_result(status, session, state.steps, index, request.request_id, nil, reason)
  end

  defp ensure_unique_request(%Turn.Request{request_id: request_id}, request_ids, index) do
    if request_id in request_ids, do: {:error, {:duplicate_sequence_request_id, index, request_id}}, else: :ok
  end

  defp session_input(%Session{session_id: session_id} = session, opts) do
    if Keyword.has_key?(opts, :store), do: session_id, else: session
  end

  defp error_session(session, request, status, reason, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} ->
        case Store.get_session(store, session.session_id) do
          {:ok, stored} -> stored
          {:error, _reason} -> put_error(session, request, status, reason)
        end

      :error ->
        put_error(session, request, status, reason)
    end
  end

  defp operation_count(%Session{} = session, opts) do
    if Keyword.get(opts, :fresh_conversation, false),
      do: 0,
      else: length(session.conversation.agent_state.operation_results)
  end

  defp put_error(session, request, :cancelled, reason),
    do: session |> maybe_put_request(request) |> Session.put_cancellation(reason)

  defp put_error(session, request, :error, reason),
    do: session |> maybe_put_request(request) |> Session.put_error(reason)

  defp terminal_result(status, session, steps, index, request_id, snapshot, reason) do
    cancellation = if match?(%Cancellation{}, reason), do: reason, else: nil

    terminal =
      Sequence.Terminal.new!(
        kind: status,
        index: index,
        request_id: request_id,
        reason: reason,
        snapshot: snapshot,
        cancellation: cancellation
      )

    Sequence.Result.new!(status: status, session: session, steps: steps, terminal: terminal)
  end

  defp put_limits(%Sequence.Result{} = result, limits, opts) do
    reason = if result.terminal, do: result.terminal.reason, else: nil
    evidence = Limits.evidence(limits, result.steps, Limits.sequence_elapsed_ms(opts), reason)
    %{result | limits: evidence}
  end

  defp runtime_clock_ms(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _clock -> System.monotonic_time(:millisecond)
    end
  end

  defp cancellation_session(%{session: %Session{} = session}, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> Store.get_session(store, session.session_id)
      :error -> {:ok, session}
    end
  end

  defp cancellation_session(_progress, _opts), do: {:error, :invalid_sequence_cancellation_progress}

  defp maybe_put_request(session, %Turn.Request{request_id: request_id} = request) do
    case List.last(session.requests) do
      %Turn.Request{request_id: ^request_id} -> session
      _last -> Session.put_request(session, request)
    end
  end

  defp maybe_put_request(session, _request), do: session

  defp persist_cancelled_session(%Session{lease: %Lease{lease_id: lease_id}} = session, opts) do
    with {:ok, store} <- fetch_store(opts) do
      Store.commit_session(store, session.session_id, lease_id, session, lease_store_opts(opts))
    end
  end

  defp persist_cancelled_session(%Session{} = session, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> Store.put_session(store, Session.clear_lease(session))
      :error -> {:ok, Session.clear_lease(session)}
    end
  end

  defp request_id(%Turn.Request{request_id: request_id}), do: request_id

  defp request_id(input) do
    input
    |> Jidoka.Schema.normalize_attrs()
    |> request_id_from_attrs()
  end

  defp request_id_from_attrs(attrs) when is_map(attrs) do
    case Jidoka.Schema.get_key(attrs, :request_id) do
      request_id when is_binary(request_id) -> request_id
      _request_id -> nil
    end
  end

  defp request_id_from_attrs(_attrs), do: nil

  defp fetch_store(opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> {:ok, store}
      :error -> {:error, :missing_harness_store}
    end
  end

  defp validate_store_mode(opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} ->
        case Store.durable_mode(store) do
          {:ok, _mode} -> :ok
          {:error, _reason} = error -> error
        end

      :error ->
        :ok
    end
  end

  defp lease_store_opts(opts), do: Keyword.take(opts, [:clock, :id_generator, :lease_ttl_ms, :owner_id])
end
