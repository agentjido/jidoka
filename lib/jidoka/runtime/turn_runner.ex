defmodule Jidoka.Runtime.TurnRunner do
  @moduledoc """
  Executes one `Jidoka.Turn.Plan` through the Runic turn spine.

  This module is the small runtime kernel under `Jidoka.Harness`. It owns the
  loop mechanics, checkpoint policy, and effect interpretation, but not
  session storage, replay, eval cases, or approval queues.
  """

  alias Jidoka.Agent
  alias Jidoka.Event
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.Controls
  alias Jidoka.Runtime.EffectInterpreter
  alias Jidoka.Runtime.Review
  alias Jidoka.Stream, as: EventStream
  alias Jidoka.Effect
  alias Jidoka.Review.Interrupt
  alias Jidoka.Turn
  alias Jidoka.Runtime.Spine.Compiler
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
    result =
      with :ok <- Agent.Spec.validate_operation_policies(plan.spec),
           state <-
             Turn.State.new!(
               spec: plan.spec,
               plan: plan,
               request: request,
               agent_state: request.agent_state,
               memory: Keyword.get(opts, :memory),
               started_at_ms: clock_ms(opts)
             ),
           :ok <- emit_turn_started(state, opts),
           {:ok, state} <- run_and_emit(state, opts, &Controls.run_input_controls/1),
           :ok <- enforce_timeout(state, opts) do
        run_loop(state, capabilities, opts)
      end

    maybe_emit_turn_failed(result, plan, request, opts)
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
        resume_with_approval_response(state, interrupt, response, capabilities, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_from_snapshot(%Turn.State{} = state, _snapshot, capabilities, opts) do
    continue_after_pending_effect(state, capabilities, opts)
  end

  defp resume_with_approval_response(state, interrupt, response, capabilities, opts) do
    response = Review.ensure_responded_at(response, clock_ms(opts))

    with :ok <- Review.validate_response(interrupt, response),
         {:ok, state} <- run_and_emit(state, opts, &Review.apply_response(&1, interrupt, response)) do
      continue_after_pending_effect(state, capabilities, opts)
    end
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

        emit_new_events(state, planned_state, opts)
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

  defp continue_after_pending_effect(%Turn.State{pending_effects: []} = state, _capabilities, _opts) do
    {:error, {:missing_pending_effect, state}}
  end

  defp continue_after_pending_effect(%Turn.State{} = state, capabilities, opts) do
    with :ok <- enforce_timeout(state, opts),
         {:ok, effect_results, state} <- interpret_or_hibernate(state, capabilities, opts),
         state_before_apply <- state,
         {:ok, %Turn.State{} = state} <- apply_effect_results(state, List.wrap(effect_results)),
         :ok <- emit_new_events(state_before_apply, state, opts),
         :ok <- enforce_timeout(state, opts) do
      continue_after_effect_applied(state, capabilities, opts)
    end
  end

  defp continue_after_effect_applied(%Turn.State{status: :finished} = state, _capabilities, opts) do
    with {:ok, state} <- run_and_emit(state, opts, &Controls.run_output_controls/1),
         :ok <- enforce_timeout(state, opts) do
      finished_state = append_turn_finished(state)
      emit_new_events(state, finished_state, opts)
      {:ok, Turn.Result.from_turn_state!(finished_state)}
    end
  end

  defp continue_after_effect_applied(%Turn.State{status: :running} = state, capabilities, opts) do
    continue_running_state(state, capabilities, opts)
  end

  defp continue_running_state(%Turn.State{pending_effects: [_effect | _rest]} = state, capabilities, opts) do
    maybe_hibernate_before_effect(state, capabilities, opts)
  end

  defp continue_running_state(%Turn.State{} = state, capabilities, opts) do
    run_loop(%Turn.State{state | loop_index: state.loop_index + 1}, capabilities, opts)
  end

  defp interpret_or_hibernate(%Turn.State{} = state, capabilities, opts) do
    case interpret_next_effects(state, capabilities, opts) do
      {:ok, %Effect.Result{} = result, %Turn.State{} = state} ->
        {:ok, result, state}

      {:ok, results, %Turn.State{} = state} when is_list(results) ->
        {:ok, results, state}

      {:interrupt, %Interrupt{} = interrupt, %Turn.State{} = state} ->
        hibernate_for_interrupt(state, interrupt, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp interpret_next_effects(%Turn.State{} = state, %Capabilities{} = capabilities, opts) do
    if parallel_operation_batch?(state, opts) do
      EffectInterpreter.interpret_operation_batch(state, capabilities, opts)
    else
      EffectInterpreter.interpret_pending(state, capabilities, opts)
    end
  end

  defp parallel_operation_batch?(%Turn.State{pending_effects: pending_effects}, opts) do
    batch_size =
      pending_effects
      |> Enum.take_while(&match?(%Effect.Intent{kind: :operation}, &1))
      |> length()

    checkpoint_policy(opts) not in [:before_each_effect, :after_each_phase] and batch_size > 1
  end

  defp apply_effect_results(%Turn.State{} = state, results) when is_list(results) do
    Enum.reduce_while(results, {:ok, state}, fn result, {:ok, state} ->
      case Turn.State.apply_effect_result(state, result) do
        {:ok, %Turn.State{} = state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp hibernate_for_interrupt(%Turn.State{} = state, %Interrupt{} = interrupt, opts) do
    event_count = length(state.events)

    with {:ok, approval_ttl_ms} <- approval_ttl_ms(interrupt, opts),
         {:ok, state, interrupt} <-
           Review.put_pending_interrupt(state, interrupt, clock_ms(opts), approval_ttl_ms) do
      emit_events(Enum.drop(state.events, event_count), opts)
      hibernate(state, Turn.Cursor.review(interrupt), opts)
    end
  end

  defp approval_ttl_ms(%Interrupt{} = interrupt, opts) do
    case Review.approval_ttl_ms(opts) do
      {:ok, nil} -> {:ok, approval_policy_ttl_ms(interrupt)}
      other -> other
    end
  end

  defp approval_policy_ttl_ms(%Interrupt{metadata: metadata}) when is_map(metadata) do
    metadata
    |> get_in(["control_metadata", "policy", "ttl_ms"])
    |> normalize_policy_ttl_ms()
  end

  defp normalize_policy_ttl_ms(ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0, do: ttl_ms
  defp normalize_policy_ttl_ms(_ttl_ms), do: nil

  defp hibernate(%Turn.State{} = state, %Turn.Cursor{} = cursor, opts) do
    hibernated_state = append_turn_hibernated(state, cursor)
    emit_new_events(state, hibernated_state, opts)
    {:hibernate, AgentSnapshot.from_turn_state!(hibernated_state, cursor, snapshot_opts(opts))}
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

  defp emit_turn_started(%Turn.State{} = state, opts) do
    Event.build(:turn_started, state.events,
      agent_id: state.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index
    )
    |> EventStream.emit(opts)
  end

  defp append_turn_hibernated(%Turn.State{} = state, %Turn.Cursor{} = cursor) do
    state
    |> Turn.Transition.new!()
    |> Turn.Transition.event(:turn_hibernated,
      agent_id: state.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index,
      data: %{cursor: Jidoka.project(cursor)}
    )
    |> Turn.Transition.commit()
  end

  defp maybe_emit_turn_failed({:error, reason} = result, %Turn.Plan{} = plan, request, opts) do
    Event.build(:turn_failed, [],
      agent_id: plan.spec.id,
      request_id: request.request_id,
      data: %{reason: inspect(reason)}
    )
    |> EventStream.emit(opts)

    result
  end

  defp maybe_emit_turn_failed(result, _plan, _request, _opts), do: result

  defp run_and_emit(%Turn.State{} = state, opts, fun) when is_function(fun, 1) do
    event_count = length(state.events)

    case fun.(state) do
      {:ok, %Turn.State{} = next_state} = ok ->
        emit_events(Enum.drop(next_state.events, event_count), opts)
        ok

      other ->
        other
    end
  end

  defp emit_new_events(%Turn.State{} = old_state, %Turn.State{} = new_state, opts) do
    new_state.events
    |> Enum.drop(length(old_state.events))
    |> emit_events(opts)
  end

  defp emit_events(events, opts) when is_list(events), do: EventStream.emit_events(events, opts)

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
