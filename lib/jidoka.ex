defmodule Jidoka do
  @moduledoc """
  Public facade for Jidoka.

  This module exposes the stable application-facing surface for the Jidoka agent
  harness:

  * an immutable `Jidoka.Agent.Spec`;
  * a compiled `Jidoka.Turn.Plan`;
  * a Runic-backed pure planning workflow;
  * an `Effect.Intent` / `Effect.Result` interpreter boundary;
  * a thin `Jidoka.Harness` execution boundary;
  * hibernate/resume from a phase-boundary snapshot.

  The facade intentionally uses short, stable verbs for the main workflow:

  * `agent/1` builds definition data;
  * `plan/1` compiles definition data into executable turn data;
  * `turn/3` runs one full model/tool turn;
  * `chat/3` runs a turn and returns only final assistant text;
  * `chat_async/3`, `stream/2`, and `await/2` support UI-friendly async flows;
  * `session/2` starts durable multi-turn state;
  * `resume/2` continues from a hibernated snapshot;
  * `pending_reviews/1`, `approve/3`, and `deny/3` cover common approval flows;
  * `export/2` writes portable JSON/YAML agent data;
  * `inspect/2`, `preflight/3`, and `project/1` expose debugging views.
  """

  alias Jidoka.Agent
  alias Jidoka.Chat
  alias Jidoka.Error
  alias Jidoka.Harness
  alias Jidoka.Harness.Session
  alias Jidoka.Inspection
  alias Jidoka.Review
  alias Jidoka.Runtime.AgentSnapshot
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

  Use this when constructing an agent from data at runtime, in tests, or from
  tooling that does not use the Spark DSL. The returned `Agent.Spec` is
  immutable definition data: it contains the agent id, model, instructions,
  controls, operations, context schema, result schema, and memory policy. It is
  not a process, session, provider client, or live capability bundle.
  """
  @spec agent(keyword() | map()) :: {:ok, Agent.Spec.t()} | {:error, term()}
  def agent(attrs), do: Agent.Spec.new(attrs)

  @doc """
  Builds a validated agent definition and raises when validation fails.

  This is useful for compile-time examples, tests, and boot-time application
  setup where invalid agent data should fail fast.
  """
  @spec agent!(keyword() | map()) :: Agent.Spec.t()
  def agent!(attrs), do: Agent.Spec.new!(attrs)

  @doc """
  Imports a JSON or YAML agent document string into `Jidoka.Agent.Spec`.

  Import is intentionally string-only at the facade. File loading, registries,
  and trust boundaries belong to the caller; Jidoka owns parsing, normalization,
  schema validation, and data-safe conversion into `Agent.Spec`.
  """
  @spec import(String.t(), keyword()) :: {:ok, Agent.Spec.t()} | {:error, term()}
  def import(contents, opts \\ []), do: Jidoka.Import.import(contents, opts)

  @doc """
  Exports an agent definition to a portable JSON or YAML document string.

  Export writes data that can be passed back into `import/2`. Runtime-only
  values are not serialized. If a context or result schema is present, provide
  a registry ref with `context_schema_ref:` or `result_schema_ref:` so the
  exported document can be resolved by the importing application.
  """
  @spec export(module() | Agent.Spec.t() | Turn.Plan.t() | keyword() | map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def export(agent_or_spec, opts \\ []), do: Jidoka.Export.export(agent_or_spec, opts)

  @doc """
  Starts a Jidoka DSL agent under the default `Jidoka.Jido` process tree.

  The started process is a `Jido.AgentServer`; incoming Jidoka turn signals are
  routed to the Runic harness and the result is written back to Jido agent state.
  """
  @spec start_agent(module() | Jido.Agent.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(agent, opts \\ []) when is_atom(agent) or is_struct(agent) do
    Jidoka.Jido.start_agent(agent, opts)
  end

  @doc """
  Stops a process-hosted Jidoka agent by pid or registered Jido agent id.
  """
  @spec stop_agent(pid() | String.t(), keyword()) :: :ok | {:error, :not_found}
  def stop_agent(pid_or_id, opts \\ []), do: Jidoka.Jido.stop_agent(pid_or_id, opts)

  @doc """
  Looks up a running Jidoka agent process by registered Jido agent id.

  This is intentionally a process-hosting helper. It does not build specs,
  create sessions, or run turns.
  """
  @spec whereis(String.t(), keyword()) :: pid() | nil
  def whereis(id, opts \\ []), do: Jidoka.Jido.whereis(id, opts)

  @doc """
  Starts a durable Jidoka session for an agent, spec, or plan.

  A session stores semantic conversation state, the latest turn result,
  hibernation snapshots, and replay data. Use it when a caller needs durable
  multi-turn behavior instead of a one-off `turn/3`.
  """
  @spec session(Jidoka.Session.agent_input()) :: {:ok, Jidoka.Session.t()} | {:error, term()}
  @spec session(Jidoka.Session.agent_input(), keyword() | String.t()) ::
          {:ok, Jidoka.Session.t()} | {:error, term()}
  def session(agent_or_plan, opts \\ []), do: Jidoka.Session.start(agent_or_plan, opts)

  @doc """
  Starts a durable Jidoka session with an explicit session id.

  Prefer this arity when the caller already has an application-level
  conversation id and wants Jidoka session state to be addressable by that id.
  """
  @spec session(Jidoka.Session.agent_input(), String.t(), keyword()) ::
          {:ok, Jidoka.Session.t()} | {:error, term()}
  def session(agent_or_plan, session_id, opts) when is_binary(session_id) and is_list(opts) do
    Jidoka.Session.start(agent_or_plan, session_id, opts)
  end

  @doc """
  Returns the current handoff owner for a conversation, if one has been recorded.

  Handoffs are durable routing data. They indicate which agent should own
  future turns for a conversation after a handoff operation succeeds.
  """
  @spec handoff(String.t()) :: Jidoka.Handoff.OwnerStore.owner() | nil
  def handoff(conversation_id), do: Jidoka.Handoff.OwnerStore.owner(conversation_id)

  @doc """
  Clears the current handoff owner for a conversation.

  Use this when an application wants to return routing control to its default
  agent selection logic.
  """
  @spec reset_handoff(String.t()) :: :ok
  def reset_handoff(conversation_id), do: Jidoka.Handoff.OwnerStore.reset(conversation_id)

  @doc """
  Compiles an agent definition into executable turn data.

  `Turn.Plan` is still pure data. It contains no live capabilities, processes,
  provider clients, or credentials. Use it when you want to inspect or cache the
  normalized runtime contract before executing a turn.
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

  This mirrors `plan/1`, but is intended for setup paths where invalid agent
  data should stop execution immediately.
  """
  @spec plan!(plan_input()) :: Turn.Plan.t()
  def plan!(%Turn.Plan{} = plan), do: plan
  def plan!(spec_input), do: spec_input |> Agent.Spec.from_input() |> plan_from_agent!()

  @doc """
  Runs one turn and returns final assistant text.

  `chat/3` is the ergonomic path for product code that only needs the final
  assistant answer. For caller-managed sessions, the updated session is returned
  alongside the text so durable state is not lost.

  Use `turn/3` when callers need the full `Turn.Result`, event journal, agent
  state, operation results, stream events, or hibernation snapshot.
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
    with {:ok, %Turn.Result{content: content}} <- turn(server, input, opts) do
      {:ok, content}
    end
  end

  def chat(spec_input, input, opts) when is_binary(input) do
    with {:ok, %Turn.Result{content: content}} <- turn(spec_input, input, opts) do
      {:ok, content}
    end
  end

  @doc """
  Starts one chat request asynchronously and returns a request handle.

  This is the UI-friendly companion to `chat/3`. Pass `stream: true` to stream
  request-scoped `Jidoka.Event` values to the caller mailbox while the task is
  running. Use `stream/2` to enumerate those events and `await/2` to collect the
  final normalized chat result.
  """
  @spec chat_async(chat_input(), String.t(), runtime_opts()) ::
          {:ok, Chat.Request.t()} | {:error, term()}
  def chat_async(target, input, opts \\ []) when is_binary(input) and is_list(opts) do
    Chat.Request.start(target, input, opts)
  end

  @doc """
  Builds a request-scoped event stream for an async chat request.

  The stream consumes events already emitted to the caller mailbox and stops at
  `:turn_finished`, `:turn_failed`, or `:turn_hibernated`.
  """
  @spec stream(Chat.Request.t(), keyword()) :: Jidoka.Stream.t()
  def stream(%Chat.Request{} = request, opts \\ []), do: Jidoka.Stream.new(request, opts)

  @doc """
  Waits for a chat request or stream to finish.

  This returns the same normalized result shape as `chat/3`, including session
  results when the request target is a `Jidoka.Session`.
  """
  @spec await(Chat.Request.t() | Jidoka.Stream.t(), keyword()) :: term()
  def await(request_or_stream, opts \\ [])
  def await(%Chat.Request{} = request, opts), do: Chat.Request.await(request, opts)
  def await(%Jidoka.Stream{} = stream, opts), do: Jidoka.Stream.await(stream, opts)

  @doc """
  Runs one agent turn through the Jidoka Runic spine.

  This is the stable core runtime entrypoint. It accepts an `Agent.Spec` or
  `Turn.Plan`, normalizes the request, runs pure workflow planning, interprets
  external effects through explicit runtime capabilities, and returns a typed
  result or snapshot.

  Use `turn/3` for deterministic tests with injected capabilities, live ReqLLM
  calls, process-hosted agents, controls, tools, hibernation, streaming, and
  trace/event inspection. If the model returns multiple independent operation
  calls in one decision, the runtime executes them as a bounded Runic-backed
  batch while preserving observation order.
  """
  @spec turn(runnable_input(), request_input(), runtime_opts()) :: run_result()
  def turn(spec_or_server, request_input, opts \\ [])

  def turn(server, input, opts)
      when is_binary(input) and is_server_ref(server) and is_list(opts) do
    Jidoka.Facade.AgentServer.turn(server, input, opts)
  end

  def turn(spec_or_plan, request_input, opts) do
    case Harness.run_turn(spec_or_plan, request_input, opts) do
      {:ok, _result} = ok ->
        ok

      {:hibernate, _snapshot} = hibernate ->
        hibernate

      {:error, reason} ->
        {:error, Error.normalize(reason, operation: :turn, phase: :harness)}
    end
  end

  @doc """
  Awaits terminal Jido status for a process-hosted Jidoka agent.

  This helper is only for process-hosted agents started through Jido. It is not
  needed for direct `turn/3` or `chat/3` calls.
  """
  @spec await_agent(server_ref(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_agent(server, opts \\ []), do: Jidoka.Facade.AgentServer.await(server, opts)

  @doc """
  Resumes from a durable agent snapshot.

  The snapshot may be an `AgentSnapshot` struct or the authenticated opaque
  string returned by `Jidoka.Runtime.AgentSnapshot.serialize/1`.
  Resume continues through the same harness boundary as `turn/3`, so callers
  provide the same runtime capabilities plus any required approval response.
  """
  @spec resume(AgentSnapshot.t() | String.t(), runtime_opts()) :: run_result()
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
  Lists pending human-review requests from a snapshot, session, or session store.

  For snapshots, this reads the review request embedded in snapshot metadata.
  For sessions and stores, it delegates to the harness session store.
  """
  @spec pending_reviews(AgentSnapshot.t() | Session.t() | Harness.Store.store() | String.t()) ::
          {:ok, [Review.Request.t()]} | {:error, term()}
  def pending_reviews(%Session{} = session), do: Harness.pending_reviews(session)

  def pending_reviews(%AgentSnapshot{} = snapshot), do: pending_reviews_from_snapshot(snapshot)

  def pending_reviews(snapshot_input) when is_binary(snapshot_input) do
    case AgentSnapshot.from_input(snapshot_input) do
      {:ok, snapshot} -> pending_reviews(snapshot)
      {:error, reason} -> {:error, reason}
    end
  end

  def pending_reviews(store), do: Harness.pending_reviews(store)

  @doc """
  Approves a pending review and resumes the target.

  The target may be a hibernated snapshot or a caller-managed session. This is a
  convenience wrapper around `Jidoka.Review.Response.approve/2` plus
  `resume/2`.
  """
  @spec approve(AgentSnapshot.t() | Session.t() | String.t(), Review.Request.t() | String.t(), runtime_opts()) ::
          run_result() | {:ok, Session.t(), Turn.Result.t()} | {:hibernate, Session.t(), AgentSnapshot.t()}
  def approve(snapshot_or_session, review_or_id, opts \\ []) do
    response = Review.Response.approve(review_or_id, review_response_opts(opts))
    resume_review_target(snapshot_or_session, response, opts)
  end

  @doc """
  Denies a pending review and resumes the target.

  Denial returns the normal resume error shape for denied approvals. Use this
  when the application wants a single facade call instead of manually building a
  `Jidoka.Review.Response`.
  """
  @spec deny(AgentSnapshot.t() | Session.t() | String.t(), Review.Request.t() | String.t(), runtime_opts()) ::
          run_result() | {:ok, Session.t(), Turn.Result.t()} | {:hibernate, Session.t(), AgentSnapshot.t()}
  def deny(snapshot_or_session, review_or_id, opts \\ []) do
    response = Review.Response.deny(review_or_id, review_response_opts(opts))
    resume_review_target(snapshot_or_session, response, opts)
  end

  @doc """
  Formats a Jidoka error or arbitrary error term for display.

  This is intended for UI/logging boundaries that need a concise message rather
  than a full Splode error struct.
  """
  @spec format_error(term()) :: String.t()
  def format_error(error), do: Error.format(error)

  @doc """
  Converts a Jidoka error or arbitrary error term into a display-oriented map.

  Values likely to contain credentials are sanitized before being returned.
  """
  @spec error_to_map(term()) :: map()
  def error_to_map(error), do: Error.to_map(error)

  @doc """
  Returns a stable inspection view for an agent, plan, turn, snapshot, journal,
  or other Jidoka data value.

  `inspect/2` is the human-facing debug surface. It favors grouped, readable
  maps over raw structs.
  """
  @spec inspect(term(), keyword()) :: term()
  def inspect(value, opts \\ []), do: Inspection.inspect(value, opts)

  @doc """
  Assembles the prompt for a turn without calling an LLM or tools.

  Use preflight to debug prompt assembly, tool metadata, memory injection, and
  request normalization before running live effects.
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

  defp pending_reviews_from_snapshot(%AgentSnapshot{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "pending_review", Map.get(metadata, :pending_review)) do
      nil ->
        {:ok, []}

      review ->
        with {:ok, review} <- Review.Request.from_input(review) do
          {:ok, [review]}
        end
    end
  end

  defp resume_review_target(%Session{} = session, %Review.Response{} = response, opts) do
    Harness.resume_session(session, resume_review_opts(opts, response))
  end

  defp resume_review_target(snapshot_input, %Review.Response{} = response, opts) do
    resume(snapshot_input, resume_review_opts(opts, response))
  end

  defp review_response_opts(opts) do
    Keyword.take(opts, [:reason, :responded_at_ms, :metadata])
  end

  defp resume_review_opts(opts, %Review.Response{} = response) do
    opts
    |> Keyword.drop([:reason, :responded_at_ms, :metadata])
    |> Keyword.put(:approval, response)
  end

  @doc """
  Projects a Jidoka data contract into a stable inspection map.

  `project/1` is the data-facing companion to `inspect/2`. It returns compact,
  deterministic maps that are useful for tests, golden files, traces, and UI
  rendering.
  """
  @spec project(term()) :: term()
  def project(value), do: Jidoka.Projection.project(value)

  @doc """
  Normalizes any error term into a Splode-backed `Jidoka.Error` exception.

  Prefer returning normalized errors from facade boundaries so callers see a
  consistent error shape even when the underlying cause came from a provider,
  store, control, or runtime capability.
  """
  @spec normalize_error(term(), keyword() | map()) :: Exception.t()
  def normalize_error(reason, context \\ %{}), do: Error.normalize(reason, context)

  defp plan_from_agent!({:ok, %Agent.Spec{} = spec}), do: Turn.Plan.new!(spec)

  defp plan_from_agent!({:error, reason}),
    do: raise(ArgumentError, "invalid agent spec: #{Kernel.inspect(reason)}")
end
