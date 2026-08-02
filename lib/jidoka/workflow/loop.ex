defmodule Jidoka.Workflow.Loop do
  @moduledoc """
  Executes one explicit bounded workflow loop.

  A loop callback receives its declared input map and the workflow context. It
  returns one of these values:

  * `{:cont, state}` or `{:cont, state, created_work}`;
  * `{:halt, value}`;
  * `{:suspend, state}` or `{:suspend, state, created_work}`; or
  * `{:error, reason}`.

  The runtime records each decision and all runtime-created work. It never
  executes more than the declared maximum number of iterations.
  """

  alias Jidoka.Workflow.Loop.{Cursor, Iteration, Result}
  alias Jidoka.Workflow.Runtime.{Retry, Value}
  alias Jidoka.Workflow.Step

  @type outcome :: {:ok, Result.t()} | {:suspend, Cursor.t()} | {:error, term()}

  @doc false
  @spec run(Step.t(), map(), map(), Cursor.t() | nil) :: outcome()
  def run(%Step{kind: :loop} = step, workflow_state, params, cursor \\ nil) do
    cursor = cursor || Cursor.new!(step.name, workflow_state.loop_state, step.max_iterations)
    iterate(step, workflow_state, params, cursor)
  end

  defp iterate(%Step{} = step, workflow_state, params, %Cursor{} = cursor) do
    if cursor.next_iteration >= cursor.max_iterations do
      {:error, {:loop_limit_exceeded, cursor}}
    else
      iteration = cursor.next_iteration

      iteration_state =
        workflow_state
        |> Map.put(:loop_state, cursor.state)
        |> Map.put(:iteration, iteration)

      with {:ok, resolved_params} <- Value.resolve(params, iteration_state),
           {:ok, resolved_params} <- ensure_input_map(resolved_params),
           {:ok, decision} <- call_loop(step, resolved_params, workflow_state.context) do
        apply_decision(step, workflow_state, params, cursor, decision)
      end
    end
  end

  defp call_loop(%Step{target: {module, function, 2}} = step, params, context) do
    Retry.call(step, fn ->
      module
      |> apply(function, [params, context])
      |> normalize_decision()
    end)
  end

  defp normalize_decision({:cont, state}), do: {:ok, {:cont, state, []}}
  defp normalize_decision({:cont, state, work}) when is_list(work), do: {:ok, {:cont, state, work}}
  defp normalize_decision({:halt, value}), do: {:ok, {:halt, value, []}}
  defp normalize_decision({:suspend, state}), do: {:ok, {:suspend, state, []}}
  defp normalize_decision({:suspend, state, work}) when is_list(work), do: {:ok, {:suspend, state, work}}
  defp normalize_decision({:error, reason}), do: {:error, reason}
  defp normalize_decision(other), do: {:error, {:invalid_loop_decision, other}}

  defp ensure_input_map(%{} = input), do: {:ok, input}
  defp ensure_input_map(input), do: {:error, {:expected_map, :loop_input, input}}

  defp apply_decision(step, workflow_state, params, cursor, {decision, value, created_work}) do
    iteration = %Iteration{
      index: cursor.next_iteration,
      state: cursor.state,
      decision: decision,
      output: value,
      created_work: created_work
    }

    cursor = Cursor.advance(cursor, value, iteration)

    case decision do
      :cont -> iterate(step, workflow_state, params, cursor)
      :halt -> {:ok, Result.from_cursor(cursor, value)}
      :suspend -> {:suspend, cursor}
    end
  end
end
