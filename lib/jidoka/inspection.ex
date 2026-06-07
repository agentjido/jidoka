defmodule Jidoka.Inspection do
  @moduledoc """
  Inspection and preflight helpers for Jidoka's data-first runtime.

  This module owns the internal implementation for the compact public
  `Jidoka.inspect/1` and `Jidoka.preflight/3` API.
  """

  alias Jidoka.Agent
  alias Jidoka.Debug
  alias Jidoka.Effect
  alias Jidoka.Error
  alias Jidoka.Inspection.Preflight
  alias Jidoka.Harness
  alias Jidoka.Memory
  alias Jidoka.Review
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn
  alias Jidoka.Runtime.Spine.Steps
  alias Jidoka.Workflow

  @type inspectable ::
          module()
          | Agent.Spec.t()
          | Turn.Plan.t()
          | Turn.Request.t()
          | Agent.State.t()
          | Turn.State.t()
          | Turn.Result.t()
          | Turn.Cursor.t()
          | AgentSnapshot.t()
          | Harness.Session.t()
          | Harness.Replay.t()
          | Debug.RequestSummary.t()
          | Debug.ReplayDiagnostics.t()
          | Effect.Journal.t()
          | Effect.Intent.t()
          | Effect.Result.t()
          | Review.Interrupt.t()
          | Review.Request.t()
          | Review.Response.t()
          | term()

  @doc "Returns a stable inspection view for a Jidoka value."
  @spec inspect(inspectable(), keyword()) :: term()
  def inspect(value, opts \\ [])

  def inspect(agent_module, opts) when is_atom(agent_module) and is_list(opts) do
    cond do
      match?({:ok, _spec}, agent_spec(agent_module)) ->
        {:ok, spec} = agent_spec(agent_module)
        agent_view(spec, Keyword.put(opts, :module, agent_module))

      match?({:ok, _workflow}, Workflow.definition(agent_module)) ->
        {:ok, workflow} = Workflow.definition(agent_module)
        workflow_view(workflow)

      true ->
        Jidoka.project(agent_module)
    end
  end

  def inspect(%Agent.Spec{} = spec, opts), do: agent_view(spec, opts)

  def inspect(%Turn.Plan{} = plan, opts) do
    plan
    |> agent_view(opts)
    |> Map.put(:kind, :plan)
  end

  def inspect(%Turn.Result{} = result, opts), do: turn_result_view(result, opts)
  def inspect(%Turn.State{} = state, opts), do: turn_state_view(state, opts)
  def inspect(%AgentSnapshot{} = snapshot, opts), do: snapshot_view(snapshot, opts)
  def inspect(%Harness.Session{} = session, _opts), do: session_view(session)
  def inspect(%Harness.Replay{} = replay, _opts), do: replay_view(replay)
  def inspect(%Debug.RequestSummary{} = summary, _opts), do: request_summary_view(summary)
  def inspect(%Debug.ReplayDiagnostics{} = diagnostics, _opts), do: replay_diagnostics_view(diagnostics)
  def inspect(%Effect.Journal{} = journal, opts), do: journal_view(journal, opts)
  def inspect(%Effect.Intent{} = intent, opts), do: intent_view(intent, opts)
  def inspect(%Effect.Result{} = result, opts), do: effect_result_view(result, opts)

  def inspect(%Review.Interrupt{} = interrupt, _opts),
    do: review_view(:review_interrupt, interrupt)

  def inspect(%Review.Request{} = request, _opts), do: review_view(:review_request, request)
  def inspect(%Review.Response{} = response, _opts), do: review_view(:review_response, response)
  def inspect(%Memory.RecallResult{} = result, _opts), do: memory_view(:memory_recall, result)
  def inspect(%Memory.WriteResult{} = result, _opts), do: memory_view(:memory_write, result)
  def inspect(%Jidoka.Eval.Run{} = run, _opts), do: eval_run_view(run)
  def inspect(%Workflow.Spec{} = workflow, _opts), do: workflow_view(workflow)
  def inspect(value, _opts), do: Jidoka.project(value)

  @doc "Assembles the prompt for a turn without interpreting any effects."
  @spec preflight(module() | Jidoka.plan_input(), Jidoka.request_input(), keyword()) ::
          {:ok, Preflight.t()} | {:error, term()}
  def preflight(spec_or_plan, request_input, opts \\ []) do
    with {:ok, plan} <- resolve_plan(spec_or_plan),
         {:ok, request} <- request(request_input, opts),
         :ok <- Agent.Spec.validate_context(plan.spec, request.context),
         {:ok, memory} <- Memory.Runtime.recall(plan.spec, request, opts) do
      plan
      |> initial_state(request, memory)
      |> Steps.assemble_prompt()
      |> preflight_from_state()
    else
      {:error, reason} ->
        {:error, Error.normalize(reason, operation: :preflight)}
    end
  end

  defp agent_view(%Turn.Plan{} = plan, opts) do
    %{
      kind: :agent,
      module: module_name(opts),
      spec: Jidoka.project(plan.spec),
      plan: Jidoka.project(plan)
    }
  end

  defp agent_view(%Agent.Spec{} = spec, opts) do
    case Turn.Plan.new(spec) do
      {:ok, plan} ->
        agent_view(plan, opts)

      {:error, reason} ->
        %{
          kind: :agent,
          module: module_name(opts),
          spec: Jidoka.project(spec),
          error: Jidoka.error_to_map(reason)
        }
    end
  end

  defp workflow_view(%Workflow.Spec{} = workflow) do
    %{
      kind: :workflow,
      graph: Workflow.Graph.project(workflow),
      workflow: Jidoka.project(workflow)
    }
  end

  defp turn_result_view(%Turn.Result{} = result, opts) do
    %{
      kind: :turn,
      status: :finished,
      content: result.content,
      timeline: timeline(result.events),
      journal: journal_view(result.journal, opts)
    }
    |> maybe_put_full(:result, result, opts)
  end

  defp turn_state_view(%Turn.State{} = state, opts) do
    %{
      kind: :turn_state,
      status: state.status,
      loop_index: state.loop_index,
      timeline: timeline(state.events),
      journal: journal_view(state.journal, opts),
      pending_effects: Enum.map(state.pending_effects, &intent_view(&1, opts)),
      pending_interrupt: Jidoka.project(state.pending_interrupt)
    }
    |> maybe_put_full(:state, state, opts)
  end

  defp snapshot_view(%AgentSnapshot{} = snapshot, opts) do
    %{
      kind: :snapshot,
      snapshot_id: snapshot.snapshot_id,
      agent_id: snapshot.agent_id,
      cursor: Jidoka.project(snapshot.cursor),
      status: snapshot.turn_state.status,
      loop_index: snapshot.turn_state.loop_index,
      timeline: timeline(snapshot.turn_state.events),
      journal: journal_view(snapshot.turn_state.journal, opts),
      pending_effects: Enum.map(snapshot.turn_state.pending_effects, &intent_view(&1, opts)),
      pending_review:
        Jidoka.project(Map.get(snapshot.metadata, "pending_review", Map.get(snapshot.metadata, :pending_review))),
      metadata: Jidoka.project(snapshot.metadata)
    }
    |> maybe_put_full(:snapshot, snapshot, opts)
  end

  defp session_view(%Harness.Session{} = session) do
    replay =
      case Harness.replay(session) do
        {:ok, replay} -> replay_view(replay)
        {:error, reason} -> %{error: Jidoka.error_to_map(reason)}
      end

    %{
      kind: :session,
      session_id: session.session_id,
      agent_id: session.agent_id,
      status: session.status,
      request_count: length(session.requests),
      snapshot_count: length(session.snapshots),
      pending_reviews: Enum.map(session.pending_reviews, &Jidoka.project/1),
      latest_cursor: latest_cursor(session),
      replay: replay,
      result: Jidoka.project(session.result),
      error: Jidoka.project(session.error)
    }
  end

  defp replay_view(%Harness.Replay{} = replay) do
    diagnostics =
      case Harness.Replay.diagnose(replay) do
        {:ok, diagnostics} -> Jidoka.project(diagnostics)
        {:error, reason} -> %{error: Jidoka.error_to_map(reason)}
      end

    %{
      kind: :replay,
      session_id: replay.session_id,
      agent_id: replay.agent_id,
      status: replay.status,
      snapshot_count: length(replay.snapshots),
      timeline: replay.timeline,
      journal: replay.journal,
      pending_reviews: replay.pending_reviews,
      diagnostics: diagnostics,
      result: replay.result,
      metadata: replay.metadata
    }
  end

  defp request_summary_view(%Debug.RequestSummary{} = summary) do
    summary
    |> Jidoka.project()
    |> Map.put(:kind, :request_debug)
  end

  defp replay_diagnostics_view(%Debug.ReplayDiagnostics{} = diagnostics) do
    diagnostics
    |> Jidoka.project()
    |> Map.put(:kind, :replay_diagnostics)
  end

  defp journal_view(%Effect.Journal{} = journal, opts) do
    intents = journal.intents |> Map.values() |> Enum.sort_by(& &1.id)
    results = journal.results |> Map.values() |> Enum.sort_by(& &1.intent_id)
    result_ids = results |> Enum.map(& &1.intent_id) |> MapSet.new()

    %{
      kind: :effect_journal,
      intent_count: length(intents),
      result_count: length(results),
      incomplete_intents:
        intents
        |> Enum.reject(&MapSet.member?(result_ids, &1.id))
        |> Enum.map(&intent_view(&1, opts)),
      intents: Enum.map(intents, &intent_view(&1, opts)),
      results: Enum.map(results, &effect_result_view(&1, opts))
    }
  end

  defp intent_view(%Effect.Intent{} = intent, opts) do
    %{
      kind: :effect_intent,
      effect_id: intent.id,
      effect_kind: intent.kind,
      idempotency: intent.idempotency,
      idempotency_key: intent.idempotency_key,
      payload_keys: payload_keys(intent.payload),
      metadata: Jidoka.project(intent.metadata)
    }
    |> maybe_put_full(:payload, intent.payload, opts)
  end

  defp effect_result_view(%Effect.Result{} = result, opts) do
    %{
      kind: :effect_result,
      intent_id: result.intent_id,
      effect_kind: result.kind,
      status: result.status,
      metadata: Jidoka.project(result.metadata)
    }
    |> maybe_put_full(:output, result.output, opts)
  end

  defp review_view(kind, review), do: Map.put(Jidoka.project(review), :kind, kind)

  defp memory_view(kind, result), do: Map.put(Jidoka.project(result), :kind, kind)

  defp eval_run_view(%Jidoka.Eval.Run{} = run) do
    %{
      kind: :eval_run,
      case_id: run.case_id,
      status: run.status,
      assertion_count: length(run.assertions),
      failed_assertions: Enum.filter(run.assertions, &(&1.status == :failed)),
      observations: run.observations,
      result: Jidoka.project(run.result),
      error: Jidoka.project(run.error)
    }
  end

  defp timeline(events), do: Jidoka.Trace.timeline(events)

  defp maybe_put_full(map, key, value, opts) do
    if Keyword.get(opts, :full?, false) do
      Map.put(map, key, Jidoka.project(value))
    else
      map
    end
  end

  defp payload_keys(%{} = payload), do: payload |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
  defp payload_keys(_payload), do: []

  defp latest_cursor(%Harness.Session{} = session) do
    case Harness.Session.latest_snapshot(session) do
      %AgentSnapshot{} = snapshot -> Jidoka.project(snapshot.cursor)
      nil -> nil
    end
  end

  defp resolve_plan(%Turn.Plan{} = plan), do: {:ok, plan}

  defp resolve_plan(%Agent.Spec{} = spec), do: Turn.Plan.new(spec)

  defp resolve_plan(agent_module) when is_atom(agent_module) do
    case agent_spec(agent_module) do
      {:ok, spec} -> Turn.Plan.new(spec)
      :error -> {:error, {:invalid_agent_module, agent_module}}
    end
  end

  defp resolve_plan(input), do: Jidoka.plan(input)

  defp request(%Turn.Request{} = request, opts),
    do: Turn.Request.from_input(request, request_opts(opts))

  defp request(input, opts) when is_binary(input) do
    request_attrs =
      [
        input: input,
        request_id: Keyword.get(opts, :request_id),
        context: Keyword.get(opts, :context, %{}),
        metadata: Keyword.get(opts, :metadata, %{}),
        agent_state: Keyword.get(opts, :agent_state, Agent.State.new!())
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    Turn.Request.from_input(request_attrs, request_opts(opts))
  end

  defp request(input, opts), do: Turn.Request.from_input(input, request_opts(opts))

  defp request_opts(opts) do
    case Keyword.fetch(opts, :id_generator) do
      {:ok, generator} -> [id_generator: generator]
      :error -> []
    end
  end

  defp initial_state(%Turn.Plan{} = plan, %Turn.Request{} = request, memory) do
    Turn.State.new!(
      spec: plan.spec,
      plan: plan,
      request: request,
      agent_state: request.agent_state,
      memory: memory
    )
  end

  defp preflight_from_state(%Turn.State{} = state) do
    Preflight.new(
      agent: Jidoka.project(state.spec),
      plan: Jidoka.project(state.plan),
      request: Jidoka.project(state.request),
      prompt: Jidoka.project(state.prompt),
      events: Jidoka.project(state.events),
      timeline: timeline(state.events),
      diagnostics: Jidoka.project(state.diagnostics)
    )
  end

  defp agent_spec(agent_module) do
    with {:module, _module} <- Code.ensure_loaded(agent_module),
         true <- function_exported?(agent_module, :spec, 0),
         %Agent.Spec{} = spec <- agent_module.spec() do
      {:ok, spec}
    else
      _other -> :error
    end
  rescue
    _exception -> :error
  end

  defp module_name(opts) do
    case Keyword.get(opts, :module) do
      module when is_atom(module) -> Kernel.inspect(module)
      _other -> nil
    end
  end
end
