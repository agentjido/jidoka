defmodule Jidoka.Runtime.TurnRunner do
  @moduledoc """
  Executes one `Jidoka.Turn.Plan` through the Runic turn spine.

  This module is the small runtime kernel under `Jidoka.Harness`. It owns the
  loop mechanics, checkpoint policy, and effect interpretation, but not
  session storage, replay, eval cases, or approval queues.
  """

  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.EffectInterpreter
  alias Jidoka.Turn
  alias Jidoka.Workflow.Compiler
  alias Runic.Workflow

  @type run_result ::
          {:ok, Turn.Result.t()}
          | {:hibernate, AgentSnapshot.t()}
          | {:error, term()}

  @spec run(Turn.Plan.t(), Turn.Request.t(), Capabilities.t(), keyword()) :: run_result()
  def run(
        %Turn.Plan{} = plan,
        %Turn.Request{} = request,
        %Capabilities{} = capabilities,
        opts \\ []
      ) do
    state =
      Turn.State.new!(
        spec: plan.spec,
        plan: plan,
        request: request,
        agent_state: request.agent_state
      )

    run_loop(state, capabilities, opts)
  end

  @spec resume(AgentSnapshot.t(), Capabilities.t(), keyword()) :: run_result()
  def resume(%AgentSnapshot{} = snapshot, %Capabilities{} = capabilities, opts \\ []) do
    with {:ok, state} <- Turn.State.from_snapshot(snapshot) do
      continue_after_pending_effect(state, capabilities, opts)
    end
  end

  defp run_loop(%Turn.State{loop_index: loop_index, plan: plan} = state, capabilities, opts) do
    if loop_index >= plan.max_model_turns do
      {:error, {:max_model_turns_exceeded, plan.max_model_turns}}
    else
      workflow = Compiler.model_turn_workflow(plan)

      planned_state =
        workflow
        |> Workflow.react_until_satisfied(state)
        |> latest_state(:plan_model_effect)

      maybe_hibernate_after_prompt(planned_state, capabilities, opts)
    end
  end

  defp maybe_hibernate_after_prompt(state, capabilities, opts) do
    case checkpoint_policy(opts) do
      :after_prompt ->
        hibernate(state, Turn.Cursor.after_prompt(), opts)

      :after_each_phase ->
        hibernate(state, Turn.Cursor.after_prompt(), opts)

      _policy ->
        maybe_hibernate_before_effect(state, capabilities, opts)
    end
  end

  defp maybe_hibernate_before_effect(
         %Turn.State{pending_effect: nil} = state,
         capabilities,
         opts
       ),
       do: continue_after_pending_effect(state, capabilities, opts)

  defp maybe_hibernate_before_effect(%Turn.State{} = state, capabilities, opts) do
    case checkpoint_policy(opts) do
      policy when policy in [:before_each_effect, :after_each_phase] ->
        hibernate(state, Turn.Cursor.before_effect(state.pending_effect), opts)

      _policy ->
        continue_after_pending_effect(state, capabilities, opts)
    end
  end

  defp continue_after_pending_effect(
         %Turn.State{pending_effect: nil} = state,
         _capabilities,
         _opts
       ) do
    {:error, {:missing_pending_effect, state}}
  end

  defp continue_after_pending_effect(%Turn.State{} = state, capabilities, opts) do
    with {:ok, effect_result, state} <- EffectInterpreter.interpret_pending(state, capabilities),
         {:ok, %Turn.State{} = state} <- Turn.State.apply_effect_result(state, effect_result) do
      case state.status do
        :finished ->
          {:ok, Turn.Result.from_turn_state!(state)}

        :running when not is_nil(state.pending_effect) ->
          maybe_hibernate_before_effect(state, capabilities, opts)

        :running ->
          run_loop(%Turn.State{state | loop_index: state.loop_index + 1}, capabilities, opts)
      end
    end
  end

  defp hibernate(%Turn.State{} = state, %Turn.Cursor{} = cursor, opts) do
    {:hibernate, AgentSnapshot.from_turn_state!(state, cursor, snapshot_opts(opts))}
  end

  defp checkpoint_policy(opts), do: Keyword.get(opts, :checkpoint, :none)

  defp snapshot_opts(opts) do
    Keyword.take(opts, [:snapshot_id, :id_generator])
  end

  defp latest_state(%Workflow{} = workflow, component) do
    workflow
    |> Workflow.raw_productions(component)
    |> Enum.filter(&match?(%Turn.State{}, &1))
    |> List.last()
  end
end
