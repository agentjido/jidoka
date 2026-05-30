defmodule Jidoka.Runtime.TurnRunner do
  @moduledoc """
  Executes one `Jidoka.Turn.Plan` through the Runic turn spine.

  This module is the small runtime kernel under `Jidoka.Harness`. It owns the
  loop mechanics, checkpoint policy, and effect interpretation, but not
  session storage, replay, eval cases, or approval queues.
  """

  alias Jidoka.Agent
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.Controls
  alias Jidoka.Runtime.EffectInterpreter
  alias Jidoka.Runtime.Review
  alias Jidoka.Effect
  alias Jidoka.Review.Interrupt
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
    with :ok <- Agent.Spec.validate_operation_policies(plan.spec),
         state <-
           Turn.State.new!(
             spec: plan.spec,
             plan: plan,
             request: request,
             agent_state: request.agent_state,
             memory: Keyword.get(opts, :memory),
             compactions: Keyword.get(opts, :compactions, []),
             started_at_ms: clock_ms(opts)
           ),
         {:ok, state} <- Controls.run_input_controls(state),
         :ok <- enforce_timeout(state, opts) do
      run_loop(state, capabilities, opts)
    end
  end

  @spec resume(AgentSnapshot.t(), Capabilities.t(), keyword()) :: run_result()
  def resume(%AgentSnapshot{} = snapshot, %Capabilities{} = capabilities, opts \\ []) do
    with {:ok, state} <- Turn.State.from_snapshot(snapshot) do
      state
      |> ensure_started_at(opts)
      |> resume_from_snapshot(snapshot, capabilities, opts)
    end
  end

  defp resume_from_snapshot(
         %Turn.State{status: :waiting, pending_interrupt: %Interrupt{} = interrupt} = state,
         %AgentSnapshot{} = snapshot,
         capabilities,
         opts
       ) do
    case Review.approval_response(opts) do
      :missing ->
        {:hibernate, snapshot}

      {:ok, %Jidoka.Review.Response{} = response} ->
        response = Review.ensure_responded_at(response, clock_ms(opts))

        with :ok <- Review.validate_response(interrupt, response),
             {:ok, state} <- Review.apply_response(state, interrupt, response) do
          continue_after_pending_effect(state, capabilities, opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_from_snapshot(%Turn.State{} = state, _snapshot, capabilities, opts) do
    continue_after_pending_effect(state, capabilities, opts)
  end

  defp run_loop(%Turn.State{loop_index: loop_index, plan: plan} = state, capabilities, opts) do
    with :ok <- enforce_timeout(state, opts) do
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

  defp maybe_hibernate_before_effect(%Turn.State{} = state, capabilities, opts) do
    with :ok <- enforce_timeout(state, opts) do
      case {Turn.State.current_pending_effect(state), checkpoint_policy(opts)} do
        {nil, _policy} ->
          continue_after_pending_effect(state, capabilities, opts)

        {%Effect.Intent{} = effect, policy}
        when policy in [:before_each_effect, :after_each_phase] ->
          hibernate(state, Turn.Cursor.before_effect(effect), opts)

        {%Effect.Intent{}, _policy} ->
          continue_after_pending_effect(state, capabilities, opts)
      end
    end
  end

  defp continue_after_pending_effect(%Turn.State{} = state, capabilities, opts) do
    if Turn.State.pending_effect?(state) do
      with :ok <- enforce_timeout(state, opts),
           {:ok, effect_result, state} <- interpret_or_hibernate(state, capabilities, opts),
           {:ok, %Turn.State{} = state} <- Turn.State.apply_effect_result(state, effect_result),
           :ok <- enforce_timeout(state, opts) do
        case state.status do
          :finished ->
            with {:ok, state} <- Controls.run_result_controls(state),
                 :ok <- enforce_timeout(state, opts) do
              {:ok, state |> append_turn_finished() |> Turn.Result.from_turn_state!()}
            end

          :running ->
            if Turn.State.pending_effect?(state) do
              maybe_hibernate_before_effect(state, capabilities, opts)
            else
              run_loop(%Turn.State{state | loop_index: state.loop_index + 1}, capabilities, opts)
            end
        end
      end
    else
      {:error, {:missing_pending_effect, state}}
    end
  end

  defp interpret_or_hibernate(%Turn.State{} = state, capabilities, opts) do
    case EffectInterpreter.interpret_pending(state, capabilities) do
      {:ok, %Effect.Result{} = result, %Turn.State{} = state} ->
        {:ok, result, state}

      {:interrupt, %Interrupt{} = interrupt, %Turn.State{} = state} ->
        hibernate_for_interrupt(state, interrupt, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hibernate_for_interrupt(%Turn.State{} = state, %Interrupt{} = interrupt, opts) do
    with {:ok, approval_ttl_ms} <- Review.approval_ttl_ms(opts),
         {:ok, state, interrupt} <-
           Review.put_pending_interrupt(state, interrupt, clock_ms(opts), approval_ttl_ms) do
      hibernate(state, Turn.Cursor.review(interrupt), opts)
    end
  end

  defp hibernate(%Turn.State{} = state, %Turn.Cursor{} = cursor, opts) do
    {:hibernate, AgentSnapshot.from_turn_state!(state, cursor, snapshot_opts(opts))}
  end

  defp checkpoint_policy(opts), do: Keyword.get(opts, :checkpoint, :none)

  defp append_turn_finished(%Turn.State{} = state) do
    state
    |> Turn.Transition.new!()
    |> Turn.Transition.event(:turn_finished,
      agent_id: state.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index
    )
    |> Turn.Transition.commit()
  end

  defp enforce_timeout(%Turn.State{plan: %{timeout_ms: timeout_ms}} = state, opts)
       when is_integer(timeout_ms) do
    elapsed_ms = clock_ms(opts) - state.started_at_ms

    if elapsed_ms > timeout_ms do
      {:error, {:turn_timeout_exceeded, timeout_ms, elapsed_ms}}
    else
      :ok
    end
  end

  defp ensure_started_at(%Turn.State{started_at_ms: nil} = state, opts) do
    %Turn.State{state | started_at_ms: clock_ms(opts)}
  end

  defp ensure_started_at(%Turn.State{} = state, _opts), do: state

  defp clock_ms(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _clock -> System.system_time(:millisecond)
    end
  end

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
