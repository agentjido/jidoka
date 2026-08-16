defmodule Jidoka.Eval do
  @moduledoc """
  Small deterministic eval runner for Jidoka turn flows.

  The runner uses the same turn path as `Jidoka.turn/3`. It adds no new runtime
  path; it only packages an agent/request pair with assertions that are useful
  for examples, regression tests, and optional live smoke checks.
  """

  alias Jidoka.Effect
  alias Jidoka.Eval.{Case, Run}
  alias Jidoka.Snapshot
  alias Jidoka.Turn
  alias Jidoka.Turn.Execution, as: TurnExecution

  @type case_input :: Case.t() | keyword() | map()

  @doc "Runs one eval case through turn execution."
  @spec run_case(case_input(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def run_case(eval_case_input, opts \\ []) do
    with {:ok, %Case{} = eval_case} <- Case.from_input(eval_case_input, opts) do
      eval_case
      |> execute(opts)
      |> build_run(eval_case)
    end
  end

  @doc "Evaluates supported assertions against a completed turn result."
  @spec evaluate(Case.t(), Turn.Result.t()) :: [Run.assertion()]
  def evaluate(%Case{assertions: assertions}, %Turn.Result{} = result) do
    Enum.map(assertions, &evaluate_assertion(&1, result))
  end

  defp execute(%Case{} = eval_case, opts) do
    TurnExecution.run(eval_case.agent, eval_case.request, opts)
  end

  defp build_run({:ok, %Turn.Result{} = result}, %Case{} = eval_case) do
    assertions = evaluate(eval_case, result)
    status = if Enum.all?(assertions, &(&1.status == :passed)), do: :passed, else: :failed

    Run.new(
      case_id: eval_case.id,
      status: status,
      result: result,
      assertions: assertions,
      observations: observations(result),
      metadata: eval_case.metadata
    )
  end

  defp build_run({:hibernate, %Snapshot{} = snapshot}, %Case{} = eval_case) do
    Run.new(
      case_id: eval_case.id,
      status: :error,
      error: %{reason: :hibernated, snapshot: Jidoka.Projection.project(snapshot)},
      assertions: [],
      metadata: eval_case.metadata
    )
  end

  defp build_run({:error, reason}, %Case{} = eval_case) do
    Run.new(
      case_id: eval_case.id,
      status: :error,
      error: Jidoka.Error.to_map(Jidoka.Error.normalize(reason, operation: :eval)),
      assertions: [],
      metadata: eval_case.metadata
    )
  end

  defp evaluate_assertion(%{kind: :contains, expected: expected}, %Turn.Result{content: content}) do
    %{
      name: :contains,
      status: assertion_status(String.contains?(content, expected)),
      expected: expected,
      actual: content
    }
  end

  defp evaluate_assertion(%{kind: :equals, expected: expected}, %Turn.Result{content: content}) do
    %{
      name: :equals,
      status: assertion_status(content == expected),
      expected: expected,
      actual: content
    }
  end

  defp evaluate_assertion(%{kind: :operation_called, expected: expected}, %Turn.Result{} = result) do
    actual = operation_names(result)

    %{
      name: :operation_called,
      status: assertion_status(expected in actual),
      expected: expected,
      actual: actual
    }
  end

  defp assertion_status(true), do: :passed
  defp assertion_status(false), do: :failed

  defp operation_names(%Turn.Result{agent_state: %{operation_results: operation_results}}) do
    Enum.map(operation_results, fn
      %Effect.OperationResult{operation: operation} -> operation
      %{operation: operation} -> operation
      %{"operation" => operation} -> operation
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp observations(%Turn.Result{} = result) do
    %{
      content: result.content,
      operation_calls: operation_names(result),
      event_count: length(result.events),
      journal_intents: map_size(result.journal.intents),
      journal_results: map_size(result.journal.results)
    }
  end
end
