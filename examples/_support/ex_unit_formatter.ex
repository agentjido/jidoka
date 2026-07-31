defmodule JidokaExamples.ExUnitFormatter do
  @moduledoc false

  use GenServer

  @schema_version 1

  @impl true
  def init(_opts) do
    state = %{path: System.fetch_env!("JIDOKA_PROOF_RESULT_PATH"), results: []}
    write_artifact!(state)
    {:ok, state}
  end

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    if proof_test?(test.tags) do
      result = %{
        schema_version: @schema_version,
        example: test.tags[:proof_example],
        scenario: scenario(test.tags[:proof_case]),
        case: scenario_case(test.tags[:proof_case]),
        status: status(test.state),
        test: %{
          file: relative_file(test.tags[:file]),
          line: test.tags[:line],
          name: test.description || to_string(test.name)
        },
        duration_ms: duration_ms(test.time),
        failure: failure(test.state)
      }

      state = %{state | results: [result | state.results]}
      write_artifact!(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:suite_finished, _times_us}, state) do
    write_artifact!(state)
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp write_artifact!(state) do
    payload = %{
      schema_version: @schema_version,
      results: Enum.sort_by(state.results, &sort_key/1)
    }

    File.write!(state.path, Jason.encode!(payload, pretty: true))
  end

  defp proof_test?(tags), do: not is_nil(tags[:proof_example]) or not is_nil(tags[:proof_case])

  defp scenario({scenario, _case_id}), do: scenario
  defp scenario(_value), do: nil

  defp scenario_case({_scenario, case_id}), do: case_id
  defp scenario_case(_value), do: nil

  defp status(nil), do: :passed

  defp status({:failed, failures}) do
    if Enum.any?(failures, &timeout_failure?/1), do: :timed_out, else: :failed
  end

  defp status({:skipped, _reason}), do: :skipped
  defp status({:excluded, _reason}), do: :excluded
  defp status({:invalid, _reason}), do: :failed
  defp status(_state), do: :failed

  defp failure(nil), do: nil
  defp failure({_status, reason}), do: format_failure(reason)
  defp failure(state), do: format_failure(state)

  defp timeout_failure?({_kind, %ExUnit.TimeoutError{}, _stacktrace}), do: true
  defp timeout_failure?(_failure), do: false

  defp format_failure(reason) do
    reason
    |> inspect(pretty: true, limit: 50)
    |> String.slice(0, 16_000)
  end

  defp duration_ms(nil), do: 0
  defp duration_ms(time_us), do: System.convert_time_unit(time_us, :microsecond, :millisecond)

  defp relative_file(file) when is_binary(file), do: Path.relative_to(file, File.cwd!())
  defp relative_file(file), do: to_string(file)

  defp sort_key(result), do: {result.example, result.scenario, result.case}
end
