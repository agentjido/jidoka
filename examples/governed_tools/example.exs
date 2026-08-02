Code.require_file(Path.expand("../loader.exs", __DIR__))

IO.puts("[setup] Loading the Governed Tools agent and deterministic capability doubles...")
JidokaExamples.Loader.load!(__DIR__)

alias JidokaExamples.GovernedTools.Scenario

result =
  case Scenario.run() do
    {:ok, result} -> result
    {:error, reason} -> raise "Governed Tools example failed: #{inspect(reason)}"
  end

IO.puts("[1/5] Static model-visible operations: #{Enum.join(result.operations, ", ")}")
IO.puts("[2/5] Skill result: #{result.skill}")
IO.puts("[3/5] Catalog result: #{result.catalog}")
IO.puts("[4/5] Browser result: #{result.browser}")
IO.puts("[5/5] Eval cases: #{inspect(result.evaluation)}")
IO.puts("      Kino graph rendered: #{result.notebook_graph?}")

IO.puts("""

Next:
  Read examples/governed_tools/README.md for the capability boundaries.
  Run mix test --only example:governed_tools for the executable proofs.
  Open examples/governed_tools/governed_tools.livemd for the local quality loop.
""")
