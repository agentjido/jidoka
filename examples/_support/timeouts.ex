defmodule JidokaExamples.Timeouts do
  @moduledoc false

  @budgets %{
    compile: 120_000,
    documentation: 120_000,
    example: 30_000,
    livebook: 30_000,
    showcase_compile: 60_000,
    showcase_focused: 60_000,
    showcase_full: 120_000
  }

  @spec fetch!(atom()) :: pos_integer()
  def fetch!(name), do: Map.fetch!(@budgets, name)
end
