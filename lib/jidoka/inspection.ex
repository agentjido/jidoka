defmodule Jidoka.Inspection do
  @moduledoc """
  Inspection and preflight helpers for Jidoka's data-first runtime.

  This module owns the internal implementation for the compact public
  `Jidoka.inspect/1` and `Jidoka.preflight/3` API.
  """

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Error
  alias Jidoka.Inspection.Preflight
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn
  alias Jidoka.Workflow.Steps

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
          | Effect.Journal.t()
          | Effect.Intent.t()
          | Effect.Result.t()
          | term()

  @doc "Returns a stable inspection view for a Jidoka value."
  @spec inspect(inspectable(), keyword()) :: term()
  def inspect(value, opts \\ [])

  def inspect(agent_module, opts) when is_atom(agent_module) and is_list(opts) do
    case agent_spec(agent_module) do
      {:ok, spec} -> agent_view(spec, Keyword.put(opts, :module, agent_module))
      :error -> Jidoka.projection(agent_module)
    end
  end

  def inspect(%Agent.Spec{} = spec, opts), do: agent_view(spec, opts)

  def inspect(%Turn.Plan{} = plan, opts) do
    plan
    |> agent_view(opts)
    |> Map.put(:kind, :plan)
  end

  def inspect(%Turn.Result{} = result, _opts), do: turn_result_view(result)
  def inspect(%Turn.State{} = state, _opts), do: turn_state_view(state)
  def inspect(%AgentSnapshot{} = snapshot, _opts), do: snapshot_view(snapshot)
  def inspect(value, _opts), do: Jidoka.projection(value)

  @doc "Assembles the prompt for a turn without interpreting any effects."
  @spec preflight(module() | Jidoka.plan_input(), Jidoka.request_input(), keyword()) ::
          {:ok, Preflight.t()} | {:error, term()}
  def preflight(spec_or_plan, request_input, opts \\ []) do
    with {:ok, plan} <- resolve_plan(spec_or_plan),
         {:ok, request} <- request(request_input, opts),
         :ok <- Agent.Spec.validate_context(plan.spec, request.context) do
      plan
      |> initial_state(request)
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
      spec: Jidoka.projection(plan.spec),
      plan: Jidoka.projection(plan)
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
          spec: Jidoka.projection(spec),
          error: Jidoka.error_to_map(reason)
        }
    end
  end

  defp turn_result_view(%Turn.Result{} = result) do
    %{
      kind: :turn,
      status: :finished,
      content: result.content,
      timeline: timeline(result.events),
      journal: Jidoka.projection(result.journal),
      result: Jidoka.projection(result)
    }
  end

  defp turn_state_view(%Turn.State{} = state) do
    %{
      kind: :turn_state,
      status: state.status,
      loop_index: state.loop_index,
      timeline: timeline(state.events),
      journal: Jidoka.projection(state.journal),
      state: Jidoka.projection(state)
    }
  end

  defp snapshot_view(%AgentSnapshot{} = snapshot) do
    %{
      kind: :snapshot,
      cursor: Jidoka.projection(snapshot.cursor),
      timeline: timeline(snapshot.turn_state.events),
      journal: Jidoka.projection(snapshot.turn_state.journal),
      snapshot: Jidoka.projection(snapshot)
    }
  end

  defp timeline(events), do: Jidoka.Extensions.Trace.timeline(events)

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

  defp initial_state(%Turn.Plan{} = plan, %Turn.Request{} = request) do
    Turn.State.new!(
      spec: plan.spec,
      plan: plan,
      request: request,
      agent_state: request.agent_state
    )
  end

  defp preflight_from_state(%Turn.State{} = state) do
    Preflight.new(
      agent: Jidoka.projection(state.spec),
      plan: Jidoka.projection(state.plan),
      request: Jidoka.projection(state.request),
      prompt: Jidoka.projection(state.prompt),
      events: Jidoka.projection(state.events),
      timeline: timeline(state.events),
      diagnostics: Jidoka.projection(state.diagnostics)
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
