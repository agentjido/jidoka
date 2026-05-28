defmodule JidokaExamples.Knowledge.FakeMCPSync do
  def run(params, _context) do
    {:ok, %{registered_count: 1, endpoint: Map.get(params, :endpoint), prefix: Map.get(params, :prefix)}}
  end
end
