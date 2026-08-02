defmodule JidokaExamples.Loader do
  @moduledoc """
  Loads one local example without adding its modules to the production build.

  Actions, controls, and model doubles load before the agent. Scenario modules
  load last because they call the compiled agent.
  """

  @spec load!(String.t()) :: [module()]
  def load!(example_root) do
    example_root
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.sort_by(&{phase(&1), &1})
    |> Enum.flat_map(&Code.require_file/1)
    |> Enum.map(&elem(&1, 0))
  end

  defp phase(path) do
    cond do
      Path.basename(path) == "agent.ex" -> 1
      "scenarios" in Path.split(path) -> 2
      Path.basename(path) == "scenario.ex" -> 3
      true -> 0
    end
  end
end
