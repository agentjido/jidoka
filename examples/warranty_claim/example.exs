Code.require_file(Path.expand("../loader.exs", __DIR__))

IO.puts("[setup] Loading the Warranty Claim agent, contracts, policy, and scripted models...")
JidokaExamples.Loader.load!(__DIR__)

alias JidokaExamples.WarrantyClaim.Scenario

IO.puts("[1/4] Comparing the code-first agent with agent.yaml.")
IO.puts("[2/4] Building text, image, and receipt input for claim CLM-2048.")
IO.puts("[3/4] Running retry, fallback, one result repair, and schema validation.")

result =
  case Scenario.run([]) do
    {:ok, result} -> result
    {:error, reason} -> raise "Warranty Claim example failed: #{inspect(reason)}"
  end

part_types = Enum.map(result.input_parts, & &1.type)

IO.puts("      Authoring parity: #{result.evidence.authoring_parity}")
IO.puts("      Input types: #{inspect(part_types)}")
IO.puts("      Fallback model: #{result.evidence.fallback_model}")
IO.puts("      Completed model effects: #{result.evidence.llm_effects}")
IO.puts("      Result repairs: #{result.evidence.result_repairs}")
IO.puts("[4/4] Final decision: #{result.decision.decision} at confidence #{result.decision.confidence}")
IO.puts("      Answer: #{result.answer}")

IO.puts("""

Next:
  Read examples/warranty_claim/lib/agent.ex for the typed contracts.
  Compare it with examples/warranty_claim/agent.yaml.
  Open examples/warranty_claim/warranty_claim.livemd for the guided walkthrough.
""")
