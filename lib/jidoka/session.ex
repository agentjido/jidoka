defmodule Jidoka.Session do
  @moduledoc """
  Ergonomic session facade backed by `Jidoka.Harness.Session`.

  `Jidoka.Harness.Session` is the durable data contract. This module is the
  developer-facing API for starting, running, resuming, and inspecting sessions
  without reaching into the lower-level harness namespace for common workflows.
  """

  alias Jidoka.Agent
  alias Jidoka.Chat
  alias Jidoka.Harness
  alias Jidoka.Harness.Session, as: HarnessSession
  alias Jidoka.Harness.Store
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  @type t :: HarnessSession.t()
  @type agent_input :: module() | Harness.plan_input()
  @type session_input :: Harness.session_input()
  @type request_input :: Harness.request_input()
  @type opts :: keyword()
  @type run_result :: Harness.session_run_result()
  @type chat_result ::
          {:ok, t(), String.t()}
          | {:hibernate, t(), AgentSnapshot.t()}
          | {:error, term()}
  @type async_result :: {:ok, Chat.Request.t()} | {:error, term()}

  @doc """
  Starts a new session for an agent, spec, or plan.

  The returned value is a `Jidoka.Harness.Session` struct. A DSL agent module is
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
      Harness.start_session(plan_input, opts)
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
  Runs one turn for a session and returns the full harness result.
  """
  @spec run(session_input(), request_input(), opts()) :: run_result()
  def run(session_or_id, request_input, opts \\ []) when is_list(opts) do
    Harness.run_session(session_or_id, request_input, opts)
  end

  @doc """
  Runs one turn for a session and returns final assistant text.

  The updated session is returned with the text so caller-managed sessions do
  not lose durable state when no store is configured.
  """
  @spec chat(session_input(), String.t(), opts()) :: chat_result()
  def chat(session_or_id, input, opts \\ []) when is_binary(input) and is_list(opts) do
    case run(session_or_id, input, opts) do
      {:ok, %HarnessSession{} = session, %Turn.Result{content: content}} ->
        {:ok, session, content}

      {:hibernate, %HarnessSession{} = session, %AgentSnapshot{} = snapshot} ->
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
    Chat.Request.start_fun(session_or_id, input, opts, fn prepared_opts ->
      chat(session_or_id, input, prepared_opts)
    end)
  end

  @doc "Waits for a request handle returned by `chat_async/3`."
  @spec await(Chat.Request.t(), opts()) :: chat_result()
  def await(%Chat.Request{} = request, opts \\ []) when is_list(opts) do
    Chat.Request.await(request, opts)
  end

  @doc """
  Resumes the latest hibernated snapshot for a session.
  """
  @spec resume(session_input(), opts()) :: run_result()
  def resume(session_or_id, opts \\ []) when is_list(opts) do
    Harness.resume_session(session_or_id, opts)
  end

  @doc "Lists pending human-review requests from a session or session store."
  @spec pending_reviews(t() | Store.store()) ::
          {:ok, [Jidoka.Review.Request.t()]} | {:error, term()}
  def pending_reviews(session_or_store), do: Harness.pending_reviews(session_or_store)

  @doc "Returns a data-only replay view for a session."
  @spec replay(t()) :: {:ok, Harness.Replay.t()} | {:error, term()}
  def replay(%HarnessSession{} = session), do: Harness.replay(session)

  @doc "Writes one memory entry through the configured memory store."
  @spec write_memory(t(), String.t(), opts()) ::
          {:ok, Jidoka.Memory.WriteResult.t()} | {:error, term()}
  def write_memory(%HarnessSession{} = session, content, opts \\ []) when is_binary(content) do
    Harness.write_memory(session, content, opts)
  end

  @doc "Fetches a persisted session from a configured session store."
  @spec get(Store.store(), String.t()) :: {:ok, t()} | {:error, term()}
  def get(store, session_id) when is_binary(session_id),
    do: Harness.store_get_session(store, session_id)

  @doc "Lists persisted sessions from a configured session store."
  @spec list(Store.store()) :: {:ok, [t()]} | {:error, term()}
  def list(store), do: Harness.store_list_sessions(store)

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
