defmodule Jidoka.Hardening.EvaluationCommand do
  @moduledoc false

  alias Jidoka.Hardening.EvaluationHarness

  @type result :: {:ok, map()} | {:error, term()}

  @spec run() :: {:ok, [result()]} | {:error, String.t(), [result()]}
  def run do
    results = EvaluationHarness.run_all_fixtures()
    Enum.each(results, &IO.puts(format_result(&1)))

    case validate(results) do
      :ok -> {:ok, results}
      {:error, reason} -> {:error, reason, results}
    end
  end

  @spec validate([result()]) :: :ok | {:error, String.t()}
  def validate(results) when is_list(results) do
    case first_failure(results) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  @spec format_result(result()) :: String.t()
  def format_result({:ok, result}) do
    final = result.final

    step_lines =
      result.steps
      |> Enum.map(fn step -> "  #{inspect(step.action)}" end)
      |> Enum.join(",")

    [
      "scenario=#{result.fixture_id}",
      "status=#{final.run_status}",
      "outcome=#{inspect(final.run_outcome)}",
      "attempts=#{final.attempt_count}",
      "verification=#{inspect(final.latest_verification_status)}",
      "artifact_refs=#{inspect(final.artifact_refs)}",
      "artifacts=#{length(final.artifact_summaries)}",
      "steps=#{step_lines}"
    ]
    |> Enum.join(" | ")
  end

  def format_result({:error, {fixture, reason}}) do
    "scenario=#{fixture.id} failed=#{inspect(reason)}"
  end

  def format_result({:error, reason}) do
    "scenario error=#{inspect(reason)}"
  end

  defp first_failure(results) do
    Enum.find_value(results, fn
      {:ok, result} -> validate_result(result)
      {:error, {fixture, reason}} -> "scenario=#{fixture.id} failed=#{inspect(reason)}"
      {:error, reason} -> "scenario error=#{inspect(reason)}"
    end)
  end

  defp validate_result(result) do
    expected = result.expected
    initial = result.steps |> List.first() |> initial_step_summary()
    final = result.final

    cond do
      is_nil(initial) ->
        "fixture #{result.fixture_id} is missing step output"

      initial.run_status != expected.initial_run_status ->
        "fixture #{result.fixture_id} failed expected classification"

      initial.latest_verification_status != expected.initial_verification_status ->
        "fixture #{result.fixture_id} failed expected classification"

      final.run_status != expected.final_run_status ->
        "fixture #{result.fixture_id} failed expected classification"

      final.run_outcome != expected.final_outcome ->
        "fixture #{result.fixture_id} failed expected classification"

      final.attempt_count != expected.final_attempt_count ->
        "fixture #{result.fixture_id} failed expected classification"

      final.latest_verification_status != expected.final_verification_status ->
        "fixture #{result.fixture_id} failed expected classification"

      length(final.artifact_summaries) != expected.artifact_count ->
        "fixture #{result.fixture_id} failed expected classification"

      true ->
        nil
    end
  end

  defp initial_step_summary(%{before: before}), do: before
  defp initial_step_summary(_step), do: nil
end
