defmodule Jidoka.Session do
  @moduledoc """
  Ergonomic session facade backed by `Jidoka.Session.Data`.

  `Jidoka.Session.Data` is the durable data contract. This module is the
  developer-facing API for starting, running, resuming, and inspecting sessions
  without reaching into lower-level execution modules for common workflows.
  """

  alias Jidoka.Agent
  alias Jidoka.Cancellation
  alias Jidoka.Chat
  alias Jidoka.Chat.Async, as: AsyncChat
  alias Jidoka.Review.Execution, as: ReviewExecution
  alias Jidoka.Session.Data, as: SessionData
  alias Jidoka.Session.Execution, as: SessionExecution
  alias Jidoka.Session.Replay
  alias Jidoka.Session.Store
  alias Jidoka.Snapshot
  alias Jidoka.Turn
  @type t :: SessionData.t()
  @type agent_input :: Turn.Plan.input()
  @type session_input :: t() | String.t()
  @type request_input :: Turn.Request.input()
  @type opts :: keyword()
  @type run_result ::
          {:ok, t(), Turn.Result.t()}
          | {:hibernate, t(), Snapshot.t()}
          | {:error, term()}
  @type chat_result ::
          {:ok, t(), String.t()}
          | {:hibernate, t(), Snapshot.t()}
          | {:cancelled, Cancellation.t()}
          | {:error, term()}
  @type async_result :: {:ok, Chat.Request.t()} | {:error, term()}

  @doc """
  Starts a new session for an agent, spec, or plan.

  The returned value is a `Jidoka.Session.Data` struct. A DSL agent module is
  accepted directly:

      {:ok, session} = Jidoka.Session.start(MyApp.SupportAgent, "support-123")

  Pass `store: ...` to persist the session immediately.
  """
  @spec start(agent_input()) :: {:ok, t()} | {:error, term()}
  @spec start(agent_input(), opts() | String.t()) :: {:ok, t()} | {:error, term()}
  def start(agent_or_plan, opts \\ [])

  def start(agent_or_plan, opts) when is_list(opts) do
    with {:ok, opts} <- normalize_start_opts(opts),
         {:ok, plan_input} <- resolve_agent_input(agent_or_plan) do
      SessionExecution.start_session(plan_input, opts)
    end
  end

  def start(agent_or_plan, session_id) when is_binary(session_id) do
    start(agent_or_plan, session_id, [])
  end

  @doc """
  Starts a new session with an explicit session id.
  """
  @spec start(agent_input(), String.t(), opts()) :: {:ok, t()} | {:error, term()}
  def start(agent_or_plan, session_id, opts) when is_binary(session_id) and is_list(opts) do
    start(agent_or_plan, Keyword.put(opts, :session_id, session_id))
  end

  @doc """
  Runs one turn for a session and returns the full session result.
  """
  @spec run(session_input(), request_input(), opts()) :: run_result()
  def run(session_or_id, request_input, opts \\ []) when is_list(opts) do
    SessionExecution.run_session(session_or_id, request_input, opts)
  end

  @doc """
  Runs one turn for a session and returns final assistant text.

  The updated session is returned with the text so caller-managed sessions do
  not lose durable state when no store is configured.
  """
  @spec chat(session_input(), String.t(), opts()) :: chat_result()
  def chat(session_or_id, input, opts \\ []) when is_binary(input) and is_list(opts) do
    case run(session_or_id, input, opts) do
      {:ok, %SessionData{} = session, %Turn.Result{content: content}} ->
        {:ok, session, content}

      {:hibernate, %SessionData{} = session, %Snapshot{} = snapshot} ->
        {:hibernate, session, snapshot}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts one session chat turn asynchronously.

  Pass `stream: true` to stream request-scoped `Jidoka.Event` values to the
  caller mailbox while the request is running.
  """
  @spec chat_async(session_input(), String.t(), opts()) :: async_result()
  def chat_async(session_or_id, input, opts \\ []) when is_binary(input) and is_list(opts) do
    runtime_opts =
      Keyword.put(opts, :on_cancelled, fn cancellation ->
        persist_forced_cancellation(session_or_id, opts, cancellation)
      end)

    AsyncChat.start_fun(session_or_id, input, runtime_opts, fn prepared_opts ->
      chat(session_or_id, input, prepared_opts)
    end)
  end

  @doc "Waits for a request handle returned by `chat_async/3`."
  @spec await(Chat.Request.t(), opts()) :: chat_result()
  def await(%Chat.Request{} = request, opts \\ []) when is_list(opts) do
    AsyncChat.await(request, opts)
  end

  @doc "Cancels an active asynchronous session request."
  @spec cancel(Chat.Request.t(), opts()) :: {:ok, Cancellation.t()} | {:error, term()}
  def cancel(%Chat.Request{} = request, opts \\ []) when is_list(opts) do
    AsyncChat.cancel(request, opts)
  end

  @doc """
  Resumes the latest hibernated snapshot for a session.
  """
  @spec resume(session_input(), opts()) :: run_result()
  def resume(session_or_id, opts \\ []) when is_list(opts) do
    SessionExecution.resume_session(session_or_id, opts)
  end

  @doc """
  Creates a new session from a safe snapshot in an existing session.

  The source session stays unchanged. By default, this function forks the
  latest snapshot. Pass `snapshot:` to select another stored snapshot.
  """
  @spec fork(session_input(), opts()) :: {:ok, t()} | {:error, term()}
  def fork(session_or_id, opts \\ []) when is_list(opts) do
    SessionExecution.fork_session(session_or_id, opts)
  end

  @doc "Recovers a session after its durable worker lease expires."
  @spec recover(String.t(), opts()) :: run_result()
  def recover(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    SessionExecution.recover_session(session_id, opts)
  end

  @doc "Lists stored sessions that are ready for crash recovery."
  @spec recoverable(Store.store(), opts()) :: {:ok, [t()]} | {:error, term()}
  def recoverable(store, opts \\ []) when is_list(opts) do
    Store.list_recoverable(store, opts)
  end

  @doc "Lists pending human-review requests from a session or session store."
  @spec pending_reviews(t() | Store.store()) ::
          {:ok, [Jidoka.Review.Request.t()]} | {:error, term()}
  def pending_reviews(session_or_store), do: ReviewExecution.pending(session_or_store)

  @doc "Returns a data-only replay view for a session."
  @spec replay(t()) :: {:ok, Replay.t()} | {:error, term()}
  def replay(%SessionData{} = session), do: Replay.from_session(session)

  @doc "Writes one memory entry through the configured memory store."
  @spec write_memory(t(), String.t(), opts()) ::
          {:ok, Jidoka.Memory.WriteResult.t()} | {:error, term()}
  def write_memory(%SessionData{} = session, content, opts \\ []) when is_binary(content) do
    SessionExecution.write_memory(session, content, opts)
  end

  @doc "Fetches a persisted session from a configured session store."
  @spec get(Store.store(), String.t()) :: {:ok, t()} | {:error, term()}
  def get(store, session_id) when is_binary(session_id),
    do: Store.get_session(store, session_id)

  @doc "Lists persisted sessions from a configured session store."
  @spec list(Store.store()) :: {:ok, [t()]} | {:error, term()}
  def list(store), do: Store.list_sessions(store)

  defp persist_forced_cancellation(session_or_id, opts, %Cancellation{} = cancellation) do
    with {:ok, store} <- Keyword.fetch(opts, :store),
         {:ok, session_id} <- cancellation_session_id(session_or_id),
         {:ok, %SessionData{} = session} <- Store.get_session(store, session_id),
         true <- active_request?(session, cancellation.request_id) do
      cancelled = SessionData.put_cancellation(session, cancellation)

      case session.lease do
        %Jidoka.Session.Lease{lease_id: lease_id} ->
          Store.commit_session(store, session_id, lease_id, cancelled,
            clock: Keyword.get(opts, :clock),
            lease_ttl_ms: Keyword.get(opts, :lease_ttl_ms, 30_000)
          )

        nil ->
          Store.put_session(store, cancelled)
      end
    else
      _result -> :ok
    end
  end

  defp cancellation_session_id(%SessionData{session_id: session_id}), do: {:ok, session_id}
  defp cancellation_session_id(session_id) when is_binary(session_id), do: {:ok, session_id}
  defp cancellation_session_id(_session), do: :error

  defp active_request?(%SessionData{status: status, requests: requests}, request_id)
       when status in [:running, :cancelled] do
    case List.last(requests) do
      %Turn.Request{request_id: ^request_id} -> true
      _request -> false
    end
  end

  defp active_request?(_session, _request_id), do: false

  defp resolve_agent_input(agent_module) when is_atom(agent_module) do
    cond do
      Code.ensure_loaded?(agent_module) and function_exported?(agent_module, :spec, 0) ->
        {:ok, agent_module.spec()}

      Code.ensure_loaded?(agent_module) and function_exported?(agent_module, :__jidoka_agent__, 0) ->
        {:ok, Agent.spec(agent_module)}

      true ->
        {:ok, agent_module}
    end
  end

  defp resolve_agent_input(agent_or_plan), do: {:ok, agent_or_plan}

  defp normalize_start_opts(opts) do
    session_id = Keyword.get(opts, :session_id)
    id = Keyword.get(opts, :id)

    cond do
      is_nil(id) ->
        {:ok, opts}

      is_nil(session_id) ->
        {:ok, opts |> Keyword.delete(:id) |> Keyword.put(:session_id, id)}

      id == session_id ->
        {:ok, Keyword.delete(opts, :id)}

      true ->
        {:error, {:conflicting_session_ids, id, session_id}}
    end
  end
end
