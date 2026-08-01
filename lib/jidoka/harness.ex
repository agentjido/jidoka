defmodule Jidoka.Harness do
  @moduledoc """
  Thin execution harness around Jidoka's data-first agent kernel.

  The harness is the named boundary where executable turn data, runtime
  capabilities, checkpoint policy, sessions, stores, replay, eval cases, memory,
  and review flows meet. Those operational concerns belong here rather than in
  the root `Jidoka` facade or the pure workflow steps.
  """

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Generation
  alias Jidoka.Cancellation
  alias Jidoka.Harness.Replay
  alias Jidoka.Harness.LeaseHeartbeat
  alias Jidoka.Harness.Session
  alias Jidoka.Harness.SessionLease
  alias Jidoka.Harness.SessionLineage
  alias Jidoka.Harness.Store
  alias Jidoka.Instructions
  alias Jidoka.Memory
  alias Jidoka.ModelPolicy
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.ReqLLM
  alias Jidoka.Runtime.TurnRunner
  alias Jidoka.Schema
  alias Jidoka.Turn

  @type agent_input :: module() | Agent.Spec.t() | keyword() | map()
  @type plan_input :: module() | Agent.Spec.t() | Turn.Plan.t() | keyword() | map()
  @type request_input ::
          Turn.Request.t() | String.t() | [Jidoka.ContentPart.input()] | keyword() | map()
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
         opts = runtime_opts(plan, opts),
         {:ok, request} <- Turn.Request.from_input(request_input, request_opts(opts)),
         :ok <- Agent.Spec.validate_context(plan.spec, request.context),
         {:ok, plan} <- Instructions.resolve(plan, request, opts),
         {:ok, memory} <- Memory.Runtime.recall(plan.spec, request, opts),
         {:ok, capabilities} <- normalize_capabilities(opts) do
      plan
      |> TurnRunner.run(request, capabilities, Keyword.put(opts, :memory, memory))
      |> maybe_capture_memory(plan.spec, request, opts)
    end
  end

  @doc """
  Resumes a hibernated agent snapshot.
  """
  @spec resume(AgentSnapshot.t() | String.t(), runtime_opts()) :: run_result()
  def resume(snapshot_input, opts \\ []) do
    with {:ok, snapshot} <- AgentSnapshot.from_input(snapshot_input),
         opts = runtime_opts(snapshot, opts),
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
         :ok <- ensure_runnable_session(session),
         {:ok, plan} <- plan(session.spec),
         opts = runtime_opts(plan, opts),
         {:ok, request} <- Turn.Request.from_input(request_input, request_opts(opts)),
         :ok <- Agent.Spec.validate_context(plan.spec, request.context),
         {:ok, plan} <- Instructions.resolve(plan, request, opts),
         {:ok, memory} <-
           Memory.Runtime.recall(
             plan.spec,
             request,
             Keyword.put(opts, :session_id, session.session_id)
           ),
         {:ok, capabilities} <- normalize_capabilities(opts),
         {:ok, session} <- claim_session(session_input, session, request, opts) do
      runtime_opts =
        opts
        |> Keyword.put(:memory, memory)
        |> Keyword.put(:session_id, session.session_id)

      with_session_lease(session, runtime_opts, fn leased_opts ->
        run_session_turn(session, plan, request, capabilities, leased_opts)
      end)
    end
  end

  @doc """
  Resumes the latest snapshot for a harness session.
  """
  @spec resume_session(session_input(), runtime_opts()) :: session_run_result()
  def resume_session(session_input, opts \\ []) do
    with {:ok, session} <- resolve_session(session_input, opts),
         {:ok, session} <- claim_resume_session(session, opts),
         {:ok, snapshot} <- latest_snapshot(session),
         opts = runtime_opts(snapshot, opts),
         {:ok, capabilities} <- normalize_capabilities(opts) do
      with_session_lease(session, opts, fn leased_opts ->
        resume_session_snapshot(session, snapshot, capabilities, leased_opts)
      end)
    end
  end

  @doc """
  Recovers a stored session after its worker lease expires.

  Recovery atomically replaces the expired lease and resumes the latest
  durable snapshot. A completed journal result is replayed. An incomplete
  effect follows its declared idempotency or reconciliation policy.
  """
  @spec recover_session(String.t(), runtime_opts()) :: session_run_result()
  def recover_session(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    with {:ok, store} <- fetch_store(opts),
         {:ok, session} <- Store.recover_session(store, session_id, lease_store_opts(opts)) do
      recover_claimed_session(session, opts)
    end
  end

  @doc """
  Creates a new session from a safe snapshot in an existing session.

  The source session is not changed. The fork keeps completed effect evidence,
  gets new session and snapshot identifiers, and records durable lineage.
  Pass `snapshot: :latest`, a snapshot id, a signed snapshot string, or a
  snapshot struct that exactly matches source session data.
  """
  @spec fork_session(session_input(), runtime_opts()) ::
          {:ok, Session.t()} | {:error, term()}
  def fork_session(session_input, opts \\ []) do
    with {:ok, source} <- resolve_session(session_input, opts),
         :ok <- ensure_forkable_session(source),
         {:ok, source_snapshot} <- select_fork_snapshot(source, Keyword.get(opts, :snapshot, :latest)),
         {:ok, lineage} <-
           SessionLineage.next(
             source.lineage,
             source.session_id,
             source_snapshot.snapshot_id,
             clock_ms(opts)
           ),
         {:ok, fork_snapshot} <- fork_snapshot(source_snapshot, source, lineage, opts),
         {:ok, fork} <- Session.fork(source, fork_snapshot, lineage, fork_session_opts(opts)),
         :ok <- ensure_fork_destination_available(fork, opts) do
      persist_session(fork, opts)
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

  @doc false
  @spec store_list_recoverable(Store.store(), keyword()) ::
          {:ok, [Session.t()]} | {:error, term()}
  def store_list_recoverable(store, opts \\ []), do: Store.list_recoverable(store, opts)

  defp run_session_turn(
         %Session{} = session,
         %Turn.Plan{} = plan,
         %Turn.Request{} = request,
         %Capabilities{} = capabilities,
         opts
       ) do
    case TurnRunner.run(plan, request, capabilities, opts) do
      {:ok, %Turn.Result{} = result} ->
        _capture = Memory.Runtime.capture_turn(plan.spec, request, result, opts)

        session
        |> Session.put_result(result)
        |> persist_session_result(opts, fn session -> {:ok, session, result} end)

      {:hibernate, %AgentSnapshot{} = snapshot} ->
        session
        |> Session.put_snapshot(snapshot)
        |> persist_session_result(opts, fn session -> {:hibernate, session, snapshot} end)

      {:error, reason} ->
        session
        |> put_session_error(reason)
        |> persist_session_result(opts, fn _session -> {:error, reason} end)
    end
  end

  defp maybe_capture_memory({:ok, %Turn.Result{} = result} = ok, spec, request, opts) do
    _capture = Memory.Runtime.capture_turn(spec, request, result, opts)
    ok
  end

  defp maybe_capture_memory(result, _spec, _request, _opts), do: result

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
        |> put_session_error(reason)
        |> persist_session_result(opts, fn _session -> {:error, reason} end)
    end
  end

  defp persist_session_result(%Session{} = session, opts, callback) do
    with {:ok, session} <- persist_session(session, opts) do
      callback.(session)
    end
  end

  defp put_session_error(%Session{} = session, reason) do
    if Cancellation.cancelled_reason?(reason) do
      Session.put_cancellation(session, reason)
    else
      Session.put_error(session, reason)
    end
  end

  defp persist_session(%Session{} = session, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> persist_stored_session(store, session, opts)
      :error -> {:ok, session}
    end
  end

  defp persist_stored_session(
         store,
         %Session{lease: %SessionLease{lease_id: lease_id}} = session,
         opts
       ) do
    Store.commit_session(store, session.session_id, lease_id, session, lease_store_opts(opts))
  end

  defp persist_stored_session(store, %Session{} = session, _opts),
    do: Store.put_session(store, session)

  defp claim_session(session_id, _session, %Turn.Request{} = request, opts) when is_binary(session_id) do
    with {:ok, store} <- fetch_store(opts) do
      Store.claim_session(store, session_id, request, lease_store_opts(opts))
    end
  end

  defp claim_session(_session_input, %Session{} = session, %Turn.Request{} = request, opts) do
    session
    |> Session.put_request(request)
    |> persist_session(opts)
  end

  defp resolve_session(%Session{} = session, _opts), do: {:ok, session}

  defp resolve_session(session_id, opts) when is_binary(session_id) do
    with {:ok, store} <- fetch_store(opts) do
      Store.get_session(store, session_id)
    end
  end

  defp claim_resume_session(%Session{} = session, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> Store.claim_resume(store, session.session_id, lease_store_opts(opts))
      :error -> ensure_resumable_session(session)
    end
  end

  defp recover_claimed_session(%Session{} = session, opts) do
    case Session.latest_snapshot(session) do
      %AgentSnapshot{} = snapshot ->
        opts = runtime_opts(snapshot, opts)

        with {:ok, capabilities} <- normalize_capabilities(opts) do
          with_session_lease(session, opts, fn leased_opts ->
            resume_session_snapshot(session, snapshot, capabilities, leased_opts)
          end)
        end

      nil ->
        restart_recovered_request(session, opts)
    end
  end

  defp restart_recovered_request(%Session{} = session, opts) do
    with %Turn.Request{} = request <- List.last(session.requests),
         {:ok, plan} <- plan(session.spec),
         opts = runtime_opts(plan, opts),
         :ok <- Agent.Spec.validate_context(plan.spec, request.context),
         {:ok, plan} <- Instructions.resolve(plan, request, opts),
         {:ok, memory} <-
           Memory.Runtime.recall(
             plan.spec,
             request,
             Keyword.put(opts, :session_id, session.session_id)
           ),
         {:ok, capabilities} <- normalize_capabilities(opts) do
      runtime_opts =
        opts
        |> Keyword.put(:memory, memory)
        |> Keyword.put(:session_id, session.session_id)

      with_session_lease(session, runtime_opts, fn leased_opts ->
        run_session_turn(session, plan, request, capabilities, leased_opts)
      end)
    else
      nil -> {:error, {:session_not_recoverable, session.session_id, :missing_request}}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_resumable_session(%Session{status: status} = session)
       when status in [:hibernated, :waiting],
       do: {:ok, session}

  defp ensure_resumable_session(%Session{session_id: session_id, status: status}),
    do: {:error, {:session_not_resumable, session_id, status}}

  defp latest_snapshot(%Session{} = session) do
    case Session.latest_snapshot(session) do
      %AgentSnapshot{} = snapshot -> {:ok, snapshot}
      nil -> {:error, {:missing_session_snapshot, session.session_id}}
    end
  end

  defp select_fork_snapshot(%Session{} = session, :latest), do: latest_snapshot(session)

  defp select_fork_snapshot(%Session{} = session, %AgentSnapshot{} = candidate) do
    case Enum.find(session.snapshots, &(&1.snapshot_id == candidate.snapshot_id)) do
      ^candidate -> {:ok, candidate}
      %AgentSnapshot{} -> {:error, {:session_snapshot_mismatch, candidate.snapshot_id}}
      nil -> {:error, {:session_snapshot_not_found, session.session_id, candidate.snapshot_id}}
    end
  end

  defp select_fork_snapshot(%Session{} = session, snapshot_input) when is_binary(snapshot_input) do
    case Enum.find(session.snapshots, &(&1.snapshot_id == snapshot_input)) do
      %AgentSnapshot{} = snapshot ->
        {:ok, snapshot}

      nil ->
        with {:ok, %AgentSnapshot{} = snapshot} <- AgentSnapshot.from_input(snapshot_input) do
          select_fork_snapshot(session, snapshot)
        end
    end
  end

  defp select_fork_snapshot(%Session{} = session, snapshot_input) do
    {:error, {:invalid_session_snapshot_selector, session.session_id, snapshot_input}}
  end

  defp fork_snapshot(%AgentSnapshot{} = snapshot, %Session{} = source, lineage, opts) do
    fork_opts =
      [
        snapshot_id: Keyword.get(opts, :fork_snapshot_id),
        id_generator: Keyword.get(opts, :id_generator),
        parent_session_id: source.session_id,
        root_session_id: lineage.root_session_id
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    AgentSnapshot.fork(snapshot, fork_opts)
  end

  defp ensure_forkable_session(%Session{status: :running, session_id: session_id}) do
    {:error, {:cannot_fork_running_session, session_id}}
  end

  defp ensure_forkable_session(%Session{}), do: :ok

  defp ensure_fork_destination_available(%Session{} = fork, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> ensure_session_absent(store, fork.session_id)
      :error -> :ok
    end
  end

  defp ensure_session_absent(store, session_id) do
    case Store.get_session(store, session_id) do
      {:error, {:session_not_found, ^session_id}} -> :ok
      {:ok, %Session{}} -> {:error, {:fork_session_already_exists, session_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_runnable_session(%Session{status: :running, session_id: session_id}) do
    {:error, {:session_already_running, session_id}}
  end

  defp ensure_runnable_session(%Session{}), do: :ok

  defp fetch_store(opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> {:ok, store}
      :error -> {:error, :missing_harness_store}
    end
  end

  defp session_opts(opts), do: Keyword.take(opts, [:session_id, :id_generator, :metadata])

  defp fork_session_opts(opts),
    do: Keyword.take(opts, [:session_id, :id_generator, :metadata])

  defp clock_ms(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _clock -> System.system_time(:millisecond)
    end
  end

  defp with_session_lease(%Session{} = session, opts, run) when is_function(run, 1) do
    opts = durable_runtime_opts(session, opts)

    case start_lease_heartbeat(session, opts) do
      {:ok, heartbeat} ->
        try do
          run.(opts)
        after
          stop_lease_heartbeat(heartbeat)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp durable_runtime_opts(
         %Session{lease: %SessionLease{} = lease} = session,
         opts
       ) do
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

  defp durable_runtime_opts(%Session{}, opts), do: opts

  defp durable_checkpoint(store, session, lease, state, intent, stage, opts) do
    cursor = Turn.Cursor.before_effect(intent)

    with {:ok, snapshot} <-
           AgentSnapshot.from_turn_state(state, cursor,
             id_generator: Keyword.get(opts, :id_generator),
             metadata: %{"durable_checkpoint" => Atom.to_string(stage)}
           ),
         {:ok, stored} <-
           Store.checkpoint_session(
             store,
             session.session_id,
             lease.lease_id,
             snapshot,
             lease_store_opts(opts)
           ) do
      run_durable_checkpoint_hook(stage, snapshot, stored, opts)
    end
  end

  defp run_durable_checkpoint_hook(stage, snapshot, stored, opts) do
    case Keyword.get(opts, :on_durable_checkpoint) do
      hook when is_function(hook, 3) -> hook.(stage, snapshot, stored)
      _hook -> :ok
    end
  end

  defp start_lease_heartbeat(
         %Session{lease: %SessionLease{lease_id: lease_id}, session_id: session_id},
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

  defp start_lease_heartbeat(%Session{}, _opts), do: {:ok, nil}

  defp stop_lease_heartbeat(nil), do: :ok

  defp stop_lease_heartbeat(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  end

  defp lease_store_opts(opts) do
    Keyword.take(opts, [:clock, :id_generator, :lease_ttl_ms, :owner_id])
  end

  defp runtime_opts(%Turn.Plan{spec: %Agent.Spec{} = spec}, opts) do
    runtime_opts(spec, opts)
  end

  defp runtime_opts(%AgentSnapshot{turn_state: %{spec: %Agent.Spec{} = spec}}, opts) do
    runtime_opts(spec, opts)
  end

  defp runtime_opts(%Agent.Spec{} = spec, opts) do
    case dsl_agent_module(spec) do
      nil ->
        Keyword.put_new(opts, :llm, ReqLLM.llm(default_llm_opts(spec, opts)))

      agent_module ->
        Agent.runtime_opts(agent_module, spec, opts)
    end
  end

  defp dsl_agent_module(%Agent.Spec{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("dsl_module", Map.get(metadata, :dsl_module))
    |> existing_dsl_agent_module()
  end

  defp existing_dsl_agent_module(module_name) when is_binary(module_name) do
    module =
      module_name
      |> String.trim()
      |> module_atom()

    if Code.ensure_loaded?(module) and function_exported?(module, :__jidoka_agent__, 0) do
      module
    end
  rescue
    ArgumentError -> nil
  end

  defp existing_dsl_agent_module(_module_name), do: nil

  defp module_atom("Elixir." <> _rest = module_name), do: String.to_existing_atom(module_name)
  defp module_atom(module_name), do: String.to_existing_atom("Elixir." <> module_name)

  defp default_llm_opts(%Agent.Spec{} = spec, opts) do
    spec.generation
    |> Generation.to_req_llm_opts()
    |> Keyword.merge(Keyword.get(opts, :llm_opts, []))
    |> Keyword.merge(Keyword.take(opts, [:stream, :stream_to, :on_event]))
    |> ModelPolicy.configure_llm_opts(spec.model, opts)
  end

  defp normalize_capabilities(opts) do
    capabilities =
      case Keyword.get(opts, :capabilities) do
        %Capabilities{} = capabilities ->
          {:ok, capabilities}

        capability_attrs when is_list(capability_attrs) or is_map(capability_attrs) ->
          capability_attrs
          |> capability_attrs_with_defaults(opts)
          |> Capabilities.new()

        nil ->
          Capabilities.new(opts)
      end

    with {:ok, capabilities} <- capabilities do
      ModelPolicy.wrap(capabilities, Keyword.get(opts, :model_policy))
    end
  end

  defp capability_attrs_with_defaults(capability_attrs, opts) do
    [:llm, :operations]
    |> Enum.reduce(Schema.normalize_attrs(capability_attrs), fn capability, attrs ->
      case Keyword.fetch(opts, capability) do
        {:ok, value} -> Schema.put_default(attrs, capability, value)
        :error -> attrs
      end
    end)
  end

  defp request_opts(opts) do
    opts
    |> Keyword.take([:id_generator, :request_id, :context, :metadata])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
