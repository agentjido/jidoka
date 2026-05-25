defmodule JidokaTest.ExamplesSmokeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @examples [
    "01_first_agent.exs",
    "02_context_and_results.exs",
    "03_actions_controls_credentials.exs",
    "04_debugging_and_tracing.exs",
    "05_workflows_and_schedules.exs",
    "06_delegation_and_imports.exs"
  ]

  test "canonical examples run provider-free in teaching order" do
    for example <- @examples do
      path = Path.expand("../../examples/#{example}", __DIR__)

      output =
        capture_io(fn ->
          assert [{_module, _binary} | _] = Code.require_file(path)
        end)

      assert output =~ example_label(example)
    end
  end

  defp example_label(example) do
    example
    |> Path.rootname()
    |> String.replace(~r/^\d+_/, "")
  end
end
