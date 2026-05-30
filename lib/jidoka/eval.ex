defmodule Jidoka.Eval do
  @moduledoc """
  Small deterministic eval runner for Jidoka harness flows.

  The runner intentionally delegates execution to `Jidoka.Harness`. It adds no
  new runtime path; it only packages an agent/request pair with assertions that
  are useful for examples, regression tests, and optional live smoke checks.
  """

  alias Jidoka.Effect
  alias Jidoka.Eval.{Case, Run}
  alias Jidoka.Harness
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Schema
  alias Jidoka.Turn

  @type case_input :: Case.t() | keyword() | map()

  @doc "Runs one eval case through the harness."
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
    []
    |> maybe_assert_contains(Schema.get_key(assertions, :contains), result)
    |> maybe_assert_equals(Schema.get_key(assertions, :equals), result)
    |> maybe_assert_operation_called(Schema.get_key(assertions, :operation_called), result)
  end

  defp execute(%Case{} = eval_case, opts) do
    Harness.run_turn(eval_case.agent, eval_case.request, opts)
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

  defp build_run({:hibernate, %AgentSnapshot{} = snapshot}, %Case{} = eval_case) do
    Run.new(
      case_id: eval_case.id,
      status: :error,
      error: %{reason: :hibernated, snapshot: Jidoka.projection(snapshot)},
      assertions: [],
      metadata: eval_case.metadata
    )
  end

  defp build_run({:error, reason}, %Case{} = eval_case) do
    Run.new(
      case_id: eval_case.id,
      status: :error,
      error: Jidoka.error_to_map(Jidoka.normalize_error(reason, operation: :eval)),
      assertions: [],
      metadata: eval_case.metadata
    )
  end

  defp maybe_assert_contains(assertions, nil, _result), do: assertions

  defp maybe_assert_contains(assertions, expected, %Turn.Result{content: content}) do
    expected
    |> List.wrap()
    |> Enum.reduce(assertions, fn expected, assertions ->
      append_assertion(assertions, %{
        name: :contains,
        status: assertion_status(is_binary(expected) and String.contains?(content, expected)),
        expected: expected,
        actual: content
      })
    end)
  end

  defp maybe_assert_equals(assertions, nil, _result), do: assertions

  defp maybe_assert_equals(assertions, expected, %Turn.Result{content: content}) do
    append_assertion(assertions, %{
      name: :equals,
      status: assertion_status(content == expected),
      expected: expected,
      actual: content
    })
  end

  defp maybe_assert_operation_called(assertions, nil, _result), do: assertions

  defp maybe_assert_operation_called(assertions, expected, %Turn.Result{} = result) do
    actual = operation_names(result)

    expected
    |> List.wrap()
    |> Enum.reduce(assertions, fn expected, assertions ->
      expected = operation_name(expected)

      append_assertion(assertions, %{
        name: :operation_called,
        status: assertion_status(expected in actual),
        expected: expected,
        actual: actual
      })
    end)
  end

  defp append_assertion(assertions, assertion), do: assertions ++ [assertion]

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

  defp operation_name(name) when is_atom(name), do: Atom.to_string(name)
  defp operation_name(name) when is_binary(name), do: name
  defp operation_name(name), do: name

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
