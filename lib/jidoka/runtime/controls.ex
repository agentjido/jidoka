defmodule Jidoka.Runtime.Controls do
  @moduledoc """
  Runtime boundary for evaluating declared agent controls.

  Controls are executable code, so they live in the runtime shell rather than
  the pure Runic workflow steps.
  """

  alias Jidoka.Agent.Spec.Controls.Input
  alias Jidoka.Agent.Spec.Controls.Operation, as: OperationControl
  alias Jidoka.Agent.Spec.Controls.Output
  alias Jidoka.Effect
  alias Jidoka.Review.Interrupt
  alias Jidoka.Runtime.Controls.Decision
  alias Jidoka.Runtime.Controls.Operation
  alias Jidoka.Turn

  @type boundary_control :: Input.t() | Output.t()
  @type operation_control :: OperationControl.t()

  @spec run_input_controls(Turn.State.t()) :: {:ok, Turn.State.t()} | {:error, term()}
  def run_input_controls(%Turn.State{} = state),
    do: run_controls(state, :input, state.spec.controls.inputs)

  @spec run_output_controls(Turn.State.t()) :: {:ok, Turn.State.t()} | {:error, term()}
  def run_output_controls(%Turn.State{} = state),
    do: run_controls(state, :output, state.spec.controls.outputs)

  @spec run_operation_controls(Turn.State.t(), Effect.Intent.t(), keyword()) ::
          {:ok, Turn.State.t()} | {:interrupt, Interrupt.t(), Turn.State.t()} | {:error, term()}
  def run_operation_controls(%Turn.State{} = state, %Effect.Intent{} = intent, opts \\ []) do
    Operation.run(state, intent, opts)
  end

  defp run_controls(%Turn.State{} = state, boundary, controls)
       when is_atom(boundary) and is_list(controls) do
    Enum.reduce_while(controls, {:ok, state}, fn control, {:ok, state} ->
      case call_control(control, state, boundary) |> Decision.normalize() do
        :allow ->
          {:cont, {:ok, append_control_event(state, control, boundary, :control_allowed)}}

        {:block, reason} ->
          {:halt, {:error, {:control_blocked, control.control, boundary, reason}}}

        {:interrupt, reason} ->
          {:halt, {:error, {:control_interrupted, control.control, boundary, reason}}}

        {:error, reason} ->
          {:halt, {:error, {:control_failed, control.control, boundary, reason}}}

        {:invalid, decision} ->
          {:halt, {:error, {:invalid_control_decision, control.control, boundary, decision}}}
      end
    end)
  end

  defp call_control(control, %Turn.State{} = state, boundary) do
    control.control.call(context(control, state, boundary))
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp context(control, %Turn.State{} = state, boundary) do
    %{
      type: :control,
      boundary: boundary,
      control: control.control,
      control_name: control_name(control.control),
      metadata: control.metadata,
      request_metadata: state.request.metadata,
      spec: state.spec,
      plan: state.plan,
      request: state.request,
      input: state.request.input,
      result: state.result,
      result_value: state.result_value,
      context: state.request.context,
      ctx:
        Jidoka.Context.from_turn_state!(state,
          boundary: boundary,
          control: control.control,
          control_name: control_name(control.control),
          metadata: control.metadata
        ),
      agent_state: state.agent_state
    }
  end

  defp append_control_event(%Turn.State{} = state, control, boundary, event) do
    state
    |> Turn.Transition.new!()
    |> Turn.Transition.event(event,
      agent_id: state.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index,
      data: %{
        boundary: boundary,
        control: control_name(control.control)
      }
    )
    |> Turn.Transition.commit()
  end

  defp control_name(control) do
    case Jidoka.Control.control_name(control) do
      {:ok, name} -> name
      {:error, _reason} -> inspect(control)
    end
  end
end
