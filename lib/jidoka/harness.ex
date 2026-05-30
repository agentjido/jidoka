defmodule Jidoka.Harness do
  @moduledoc """
  Thin execution harness around Jidoka's data-first agent kernel.

  The harness is the named boundary where executable turn data, runtime
  capabilities, checkpoint policy, sessions, stores, replay, eval cases, memory,
  and review flows meet. Those operational concerns belong here rather than in
  the root `Jidoka` facade or the pure workflow steps.
  """

  alias Jidoka.Agent
  alias Jidoka.Harness.Replay
  alias Jidoka.Harness.Session
  alias Jidoka.Harness.Store
  alias Jidoka.Memory
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.TurnRunner
  alias Jidoka.Turn

  @type agent_input :: Agent.Spec.t() | keyword() | map()
  @type plan_input :: Agent.Spec.t() | Turn.Plan.t() | keyword() | map()
  @type request_input :: Turn.Request.t() | String.t() | keyword() | map()
  @type runtime_opts :: keyword()
  @type session_input :: Session.t() | String.t()

  @type run_result :: TurnRunner.run_result()
  @type session_run_result ::
          {:ok, Session.t(), Turn.Result.t()}
          | {:hibernate, Session.t(), AgentSnapshot.t()}
          | {:error, term()}

  @doc """
  Runs one agent turn through the harness.
  """
  @spec run_turn(plan_input(), request_input(), runtime_opts()) :: run_result()
  def run_turn(spec_or_plan, request_input, opts \\ []) do
    with {:ok, plan} <- plan(spec_or_plan),
         {:ok, request} <- Turn.Request.from_input(request_input, request_opts(opts)),
         :ok <- Agent.Spec.validate_context(plan.spec, request.context),
         {:ok, memory} <- Memory.Runtime.recall(plan.spec, request, opts),
         {:ok, capabilities} <- normalize_capabilities(opts) do
      TurnRunner.run(plan, request, capabilities, Keyword.put(opts, :memory, memory))
    end
  end

  @doc """
  Resumes a hibernated agent snapshot.
  """
  @spec resume(AgentSnapshot.t() | keyword() | map() | String.t(), runtime_opts()) :: run_result()
  def resume(snapshot_input, opts \\ []) do
    with {:ok, snapshot} <- AgentSnapshot.from_input(snapshot_input),
         {:ok, capabilities} <- normalize_capabilities(opts) do
      TurnRunner.resume(snapshot, capabilities, opts)
    end
  end

  @doc """
  Starts a persisted or caller-managed harness session.

  Pass `store: {Jidoka.Harness.Store.InMemory, pid: pid}` or another
  `Jidoka.Harness.Store` implementation to persist the session immediately.
  """
  @spec start_session(plan_input(), runtime_opts()) :: {:ok, Session.t()} | {:error, term()}
  def start_session(spec_or_plan, opts \\ []) do
    with {:ok, plan} <- plan(spec_or_plan),
         {:ok, session} <- Session.start(plan.spec, session_opts(opts)) do
      persist_session(session, opts)
    end
  end

  @doc """
  Runs one turn for a harness session and persists the resulting session state.
  """
  @spec run_session(session_input(), request_input(), runtime_opts()) :: session_run_result()
  def run_session(session_input, request_input, opts \\ []) do
    with {:ok, session} <- resolve_session(session_input, opts),
         {:ok, plan} <- plan(session.spec),
         {:ok, request} <- Turn.Request.from_input(request_input, request_opts(opts)),
         :ok <- Agent.Spec.validate_context(plan.spec, request.context),
         {:ok, memory} <-
           Memory.Runtime.recall(
             plan.spec,
             request,
             Keyword.put(opts, :session_id, session.session_id)
           ),
         {:ok, capabilities} <- normalize_capabilities(opts) do
      session
      |> Session.put_request(request)
      |> run_session_turn(plan, request, capabilities, Keyword.put(opts, :memory, memory))
    end
  end

  @doc """
  Resumes the latest snapshot for a harness session.
  """
  @spec resume_session(session_input(), runtime_opts()) :: session_run_result()
  def resume_session(session_input, opts \\ []) do
    with {:ok, session} <- resolve_session(session_input, opts),
         {:ok, snapshot} <- latest_snapshot(session),
         {:ok, capabilities} <- normalize_capabilities(opts) do
      session
      |> resume_session_snapshot(snapshot, capabilities, opts)
    end
  end

  @doc "Lists pending human-review requests from a session or store."
  @spec pending_reviews(Session.t() | Store.store()) ::
          {:ok, [Jidoka.Review.Request.t()]} | {:error, term()}
  def pending_reviews(%Session{} = session), do: {:ok, session.pending_reviews}
  def pending_reviews(store), do: Store.pending_reviews(store)

  @doc "Returns a data-only replay view for a session or snapshot."
  @spec replay(Session.t() | AgentSnapshot.t()) :: {:ok, Replay.t()} | {:error, term()}
  def replay(%Session{} = session), do: Replay.from_session(session)
  def replay(%AgentSnapshot{} = snapshot), do: Replay.from_snapshot(snapshot)

  @doc "Writes one memory entry through the configured memory store."
  @spec write_memory(plan_input() | Session.t(), String.t(), runtime_opts()) ::
          {:ok, Memory.WriteResult.t()} | {:error, term()}
  def write_memory(spec_or_session, content, opts \\ [])

  def write_memory(%Session{} = session, content, opts) when is_binary(content) do
    Memory.Runtime.write(
      session.spec,
      content,
      Keyword.put(opts, :session_id, session.session_id)
    )
  end

  def write_memory(spec_or_plan, content, opts) when is_binary(content) do
    with {:ok, plan} <- plan(spec_or_plan) do
      Memory.Runtime.write(plan.spec, content, opts)
    end
  end

  @doc false
  @spec plan(plan_input()) :: {:ok, Turn.Plan.t()} | {:error, term()}
  def plan(%Turn.Plan{} = plan), do: {:ok, plan}

  def plan(spec_input) do
    with {:ok, spec} <- Agent.Spec.from_input(spec_input) do
      Turn.Plan.new(spec)
    end
  end

  @doc false
  @spec store_get_session(Store.store(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def store_get_session(store, session_id), do: Store.get_session(store, session_id)

  @doc false
  @spec store_list_sessions(Store.store()) :: {:ok, [Session.t()]} | {:error, term()}
  def store_list_sessions(store), do: Store.list_sessions(store)

  defp run_session_turn(
         %Session{} = session,
         %Turn.Plan{} = plan,
         %Turn.Request{} = request,
         %Capabilities{} = capabilities,
         opts
       ) do
    case TurnRunner.run(plan, request, capabilities, opts) do
      {:ok, %Turn.Result{} = result} ->
        session
        |> Session.put_result(result)
        |> persist_session_result(opts, fn session -> {:ok, session, result} end)

      {:hibernate, %AgentSnapshot{} = snapshot} ->
        session
        |> Session.put_snapshot(snapshot)
        |> persist_session_result(opts, fn session -> {:hibernate, session, snapshot} end)

      {:error, reason} ->
        session
        |> Session.put_error(reason)
        |> persist_session_result(opts, fn _session -> {:error, reason} end)
    end
  end

  defp resume_session_snapshot(
         %Session{} = session,
         %AgentSnapshot{} = snapshot,
         %Capabilities{} = capabilities,
         opts
       ) do
    case TurnRunner.resume(snapshot, capabilities, opts) do
      {:ok, %Turn.Result{} = result} ->
        session
        |> Session.put_result(result)
        |> persist_session_result(opts, fn session -> {:ok, session, result} end)

      {:hibernate, %AgentSnapshot{} = snapshot} ->
        session
        |> Session.put_snapshot(snapshot)
        |> persist_session_result(opts, fn session -> {:hibernate, session, snapshot} end)

      {:error, reason} ->
        session
        |> Session.put_error(reason)
        |> persist_session_result(opts, fn _session -> {:error, reason} end)
    end
  end

  defp persist_session_result(%Session{} = session, opts, callback) do
    with {:ok, session} <- persist_session(session, opts) do
      callback.(session)
    end
  end

  defp persist_session(%Session{} = session, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> Store.put_session(store, session)
      :error -> {:ok, session}
    end
  end

  defp resolve_session(%Session{} = session, _opts), do: {:ok, session}

  defp resolve_session(session_id, opts) when is_binary(session_id) do
    with {:ok, store} <- fetch_store(opts) do
      Store.get_session(store, session_id)
    end
  end

  defp latest_snapshot(%Session{} = session) do
    case Session.latest_snapshot(session) do
      %AgentSnapshot{} = snapshot -> {:ok, snapshot}
      nil -> {:error, {:missing_session_snapshot, session.session_id}}
    end
  end

  defp fetch_store(opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> {:ok, store}
      :error -> {:error, :missing_harness_store}
    end
  end

  defp session_opts(opts), do: Keyword.take(opts, [:session_id, :id_generator, :metadata])

  defp normalize_capabilities(opts) do
    case Keyword.get(opts, :capabilities) do
      %Capabilities{} = capabilities ->
        {:ok, capabilities}

      capability_attrs when is_list(capability_attrs) or is_map(capability_attrs) ->
        Capabilities.new(capability_attrs)

      nil ->
        Capabilities.new(opts)
    end
  end

  defp request_opts(opts) do
    case Keyword.fetch(opts, :id_generator) do
      {:ok, generator} -> [id_generator: generator]
      :error -> []
    end
  end
end
