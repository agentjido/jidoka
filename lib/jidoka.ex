defmodule Jidoka do
  @moduledoc """
  Minimal V2 spike.

  This module intentionally exposes a tiny public surface that proves the new
  architecture can work:

  * an immutable `Jidoka.Agent.Spec`;
  * a compiled `Jidoka.Turn.Plan`;
  * a Runic-backed pure planning workflow;
  * an `Effect.Intent` / `Effect.Result` interpreter boundary;
  * a thin `Jidoka.Harness` execution boundary;
  * hibernate/resume from a phase-boundary snapshot.
  """

  alias Jidoka.Agent
  alias Jidoka.Error
  alias Jidoka.Harness
  alias Jidoka.Harness.Session
  alias Jidoka.Inspection
  alias Jidoka.Runtime.AgentServerState
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.Signals
  alias Jidoka.Turn

  @type agent_input :: Agent.Spec.t() | keyword() | map()
  @type plan_input :: Agent.Spec.t() | Turn.Plan.t() | keyword() | map()
  @type request_input :: Turn.Request.t() | String.t() | keyword() | map()
  @type runtime_opts :: keyword()
  @type server_ref :: Jido.AgentServer.server()
  @type runnable_input :: plan_input() | server_ref()
  @type chat_input :: runnable_input() | Session.t()

  @type run_result ::
          {:ok, Turn.Result.t()}
          | {:hibernate, AgentSnapshot.t()}
          | {:error, term()}

  defguardp is_server_ref(server)
            when is_pid(server) or is_binary(server) or
                   (is_tuple(server) and tuple_size(server) == 3)

  @doc """
  Builds a validated agent definition.

  This is the root-level convenience wrapper around `Jidoka.Agent.Spec.new/1`.
  The returned `Agent.Spec` is immutable definition data, not a process or
  session.
  """
  @spec agent(keyword() | map()) :: {:ok, Agent.Spec.t()} | {:error, term()}
  def agent(attrs), do: Agent.Spec.new(attrs)

  @doc """
  Builds a validated agent definition and raises on invalid input.
  """
  @spec agent!(keyword() | map()) :: Agent.Spec.t()
  def agent!(attrs), do: Agent.Spec.new!(attrs)

  @doc """
  Alias for `agent/1`.

  Kept while the V2 spike is settling. Prefer `agent/1` in new examples.
  """
  @spec new_agent(keyword() | map()) :: {:ok, Agent.Spec.t()} | {:error, term()}
  def new_agent(attrs), do: agent(attrs)

  @doc """
  Imports a JSON/YAML agent document string into `Jidoka.Agent.Spec`.
  """
  @spec import(String.t(), keyword()) :: {:ok, Agent.Spec.t()} | {:error, term()}
  def import(contents, opts \\ []), do: Jidoka.Import.import(contents, opts)

  @doc """
  Starts a Jidoka DSL agent under the default `Jidoka.Jido` process tree.

  The started process is a `Jido.AgentServer`; incoming Jidoka turn signals are
  routed to the Runic harness and the result is written back to Jido agent state.
  """
  @spec start_agent(module() | Jido.Agent.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(agent, opts \\ []) when is_atom(agent) or is_struct(agent) do
    Jidoka.Jido.start_agent(agent, opts)
  end

  @doc "Stops a Jidoka agent process by pid or registered Jido agent id."
  @spec stop_agent(pid() | String.t(), keyword()) :: :ok | {:error, :not_found}
  def stop_agent(pid_or_id, opts \\ []), do: Jidoka.Jido.stop_agent(pid_or_id, opts)

  @doc "Looks up a running Jidoka agent process by registered Jido agent id."
  @spec whereis(String.t(), keyword()) :: pid() | nil
  def whereis(id, opts \\ []), do: Jidoka.Jido.whereis(id, opts)

  @doc """
  Starts a durable Jidoka session for an agent, spec, or plan.

  This is the root-level convenience wrapper around `Jidoka.Session.start/2`.
  The returned value is a `Jidoka.Harness.Session` data struct.
  """
  @spec session(Jidoka.Session.agent_input()) :: {:ok, Jidoka.Session.t()} | {:error, term()}
  @spec session(Jidoka.Session.agent_input(), keyword() | String.t()) ::
          {:ok, Jidoka.Session.t()} | {:error, term()}
  def session(agent_or_plan, opts \\ []), do: Jidoka.Session.start(agent_or_plan, opts)

  @doc """
  Starts a durable Jidoka session with an explicit session id.
  """
  @spec session(Jidoka.Session.agent_input(), String.t(), keyword()) ::
          {:ok, Jidoka.Session.t()} | {:error, term()}
  def session(agent_or_plan, session_id, opts) when is_binary(session_id) and is_list(opts) do
    Jidoka.Session.start(agent_or_plan, session_id, opts)
  end

  @doc "Returns the current handoff owner for a conversation, if one has been recorded."
  @spec handoff_owner(String.t()) :: Jidoka.Handoff.OwnerStore.owner() | nil
  def handoff_owner(conversation_id), do: Jidoka.Handoff.OwnerStore.owner(conversation_id)

  @doc "Clears the current handoff owner for a conversation."
  @spec reset_handoff(String.t()) :: :ok
  def reset_handoff(conversation_id), do: Jidoka.Handoff.OwnerStore.reset(conversation_id)

  @doc """
  Compiles an agent definition into executable turn data.

  `Turn.Plan` remains data. It contains no live capabilities, processes, provider
  clients, or credentials.
  """
  @spec plan(plan_input()) :: {:ok, Turn.Plan.t()} | {:error, term()}
  def plan(%Turn.Plan{} = plan), do: {:ok, plan}

  def plan(spec_input) do
    with {:ok, spec} <- Agent.Spec.from_input(spec_input) do
      Turn.Plan.new(spec)
    end
  end

  @doc """
  Compiles an agent definition into executable turn data and raises on failure.
  """
  @spec plan!(plan_input()) :: Turn.Plan.t()
  def plan!(%Turn.Plan{} = plan), do: plan
  def plan!(spec_input), do: spec_input |> Agent.Spec.from_input() |> plan_from_agent!()

  @doc """
  Alias for `plan!/1`.

  Kept while the V2 spike is settling. Prefer `plan!/1` in new examples.
  """
  @spec compile_turn_plan!(Agent.Spec.t()) :: Turn.Plan.t()
  def compile_turn_plan!(%Agent.Spec{} = spec), do: plan!(spec)

  @doc """
  Runs one turn and returns final assistant text.

  For caller-managed sessions, the updated session is returned alongside the
  text so durable state is not lost.

  Use `run_turn/3` when callers need the full `Turn.Result`, journal, state, or
  checkpoint response.
  """
  @spec chat(chat_input(), String.t(), runtime_opts()) ::
          {:ok, String.t()}
          | {:ok, Jidoka.Session.t(), String.t()}
          | {:hibernate, AgentSnapshot.t()}
          | {:hibernate, Jidoka.Session.t(), AgentSnapshot.t()}
          | {:error, term()}
  def chat(spec_or_server, input, opts \\ [])

  def chat(%Session{} = session, input, opts) when is_binary(input) and is_list(opts) do
    case Jidoka.Session.chat(session, input, opts) do
      {:ok, session, content} -> {:ok, session, content}
      {:hibernate, session, snapshot} -> {:hibernate, session, snapshot}
      {:error, reason} -> {:error, Error.normalize(reason, operation: :chat, phase: :session)}
    end
  end

  def chat(server, input, opts)
      when is_binary(input) and is_server_ref(server) and is_list(opts) do
    with {:ok, %Turn.Result{content: content}} <- run_turn(server, input, opts) do
      {:ok, content}
    end
  end

  def chat(spec_input, input, opts) when is_binary(input) do
    with {:ok, %Turn.Result{content: content}} <- run_turn(spec_input, input, opts) do
      {:ok, content}
    end
  end

  @doc """
  Runs one agent turn through the V2 Runic spine.

  This is the stable core runtime entrypoint. It accepts an `Agent.Spec` or
  `Turn.Plan`, normalizes the request, runs pure workflow planning, interprets
  external effects through explicit runtime capabilities, and returns a typed result or
  snapshot.
  """
  @spec run_turn(runnable_input(), request_input(), runtime_opts()) :: run_result()
  def run_turn(spec_or_server, request_input, opts \\ [])

  def run_turn(server, input, opts)
      when is_binary(input) and is_server_ref(server) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    runtime_opts =
      opts
      |> Keyword.drop([:context, :metadata, :request_id, :timeout])
      |> Keyword.merge(Keyword.get(opts, :runtime_opts, []))

    signal =
      Signals.turn_run(input,
        request_id: Keyword.get(opts, :request_id),
        context: Keyword.get(opts, :context),
        metadata: Keyword.get(opts, :metadata),
        runtime_opts: runtime_opts
      )

    result =
      with {:ok, server} <- resolve_server_ref(server),
           {:ok, agent} <- Jido.AgentServer.call(server, signal, timeout) do
        run_result_from_jido_agent(agent)
      end

    case result do
      {:ok, _result} = ok ->
        ok

      {:hibernate, _snapshot} = hibernate ->
        hibernate

      {:error, reason} ->
        {:error,
         Error.normalize(reason,
           operation: :run_turn,
           phase: :agent_server,
           target: server,
           request_id: Keyword.get(opts, :request_id)
         )}
    end
  end

  def run_turn(spec_or_plan, request_input, opts) do
    case Harness.run_turn(spec_or_plan, request_input, opts) do
      {:ok, _result} = ok ->
        ok

      {:hibernate, _snapshot} = hibernate ->
        hibernate

      {:error, reason} ->
        {:error, Error.normalize(reason, operation: :run_turn, phase: :harness)}
    end
  end

  @doc """
  Awaits terminal Jido status for a process-hosted Jidoka agent.
  """
  @spec await_agent(server_ref(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_agent(server, opts \\ []) do
    result =
      with {:ok, server} <- resolve_server_ref(server) do
        Jido.AgentServer.await_completion(server, opts)
      end

    case result do
      {:ok, _result} = ok ->
        ok

      {:error, reason} ->
        {:error, Error.normalize(reason, operation: :await_agent, target: server)}
    end
  end

  @doc """
  Resumes from a durable agent snapshot.

  The snapshot may be an `AgentSnapshot` struct, map-shaped snapshot data, or
  the opaque string returned by `Jidoka.Runtime.AgentSnapshot.serialize/1`.
  """
  @spec resume(AgentSnapshot.t() | keyword() | map() | String.t(), runtime_opts()) :: run_result()
  def resume(snapshot_input, opts \\ []) do
    case Harness.resume(snapshot_input, opts) do
      {:ok, _result} = ok ->
        ok

      {:hibernate, _snapshot} = hibernate ->
        hibernate

      {:error, reason} ->
        {:error, Error.normalize(reason, operation: :resume, phase: :harness)}
    end
  end

  @doc """
  Formats a Jidoka error or arbitrary error term for display.
  """
  @spec format_error(term()) :: String.t()
  def format_error(error), do: Error.format(error)

  @doc """
  Converts a Jidoka error or arbitrary error term into a display-oriented map.
  """
  @spec error_to_map(term()) :: map()
  def error_to_map(error), do: Error.to_map(error)

  @doc """
  Returns a stable inspection view for an agent, plan, turn, snapshot, journal,
  or other Jidoka data value.
  """
  @spec inspect(term(), keyword()) :: term()
  def inspect(value, opts \\ []), do: Inspection.inspect(value, opts)

  @doc """
  Assembles the prompt for a turn without calling an LLM or tools.
  """
  @spec preflight(plan_input() | module(), request_input(), runtime_opts()) ::
          {:ok, Inspection.Preflight.t()} | {:error, term()}
  def preflight(spec_or_plan, request_input, opts \\ []) do
    case Inspection.preflight(spec_or_plan, request_input, opts) do
      {:ok, _preflight} = ok ->
        ok

      {:error, reason} ->
        {:error, Error.normalize(reason, operation: :preflight)}
    end
  end

  @doc """
  Projects a Jidoka data contract into a stable inspection map.
  """
  @spec projection(term()) :: term()
  def projection(value), do: Jidoka.Projection.project(value)

  @doc """
  Normalizes any error term into a Splode-backed `Jidoka.Error` exception.
  """
  @spec normalize_error(term(), keyword() | map()) :: Exception.t()
  def normalize_error(reason, context \\ %{}), do: Error.normalize(reason, context)

  defp plan_from_agent!({:ok, %Agent.Spec{} = spec}), do: Turn.Plan.new!(spec)

  defp plan_from_agent!({:error, reason}),
    do: raise(ArgumentError, "invalid agent spec: #{Kernel.inspect(reason)}")

  defp run_result_from_jido_agent(%Jido.Agent{state: state}) do
    case AgentServerState.from_jido_state(state) do
      {:ok, agent_server_state} ->
        AgentServerState.to_run_result(agent_server_state)

      {:error, reason} ->
        {:error, Error.normalize(reason, operation: :run_turn, phase: :agent_server)}
    end
  end

  defp resolve_server_ref(server) when is_binary(server) do
    case whereis(server) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  defp resolve_server_ref(server), do: {:ok, server}
end
