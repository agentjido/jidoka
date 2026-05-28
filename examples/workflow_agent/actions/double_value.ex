defmodule JidokaExamples.Workflows.DoubleValue do
  use Jidoka.Action,
    name: "example_double_value",
    description: "Doubles the input value.",
    schema: Zoi.object(%{value: Zoi.integer()})

  @impl true
  def run(%{value: value}, _context), do: {:ok, %{value: value * 2}}
end
