defmodule JidokaExamples.Workflows.AddOne do
  use Jidoka.Action,
    name: "example_add_one",
    description: "Adds one to the input value.",
    schema: Zoi.object(%{value: Zoi.integer()})

  @impl true
  def run(%{value: value}, _context), do: {:ok, %{value: value + 1}}
end
