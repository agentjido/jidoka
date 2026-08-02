Code.require_file(Path.expand("../loader.exs", __DIR__))

IO.puts("[setup] Loading the smallest Jidoka agent and its deterministic scenario...")
JidokaExamples.Loader.load!(__DIR__)

alias JidokaExamples.GettingStarted.Scenario

IO.puts("[1/4] Compiled one agent with a model and one instruction.")
IO.puts("[2/4] Preflight the request without calling the model.")
IO.puts("[3/4] Send: What can you help me with?")

result =
  case Scenario.run([]) do
    {:ok, result} -> result
    {:error, reason} -> raise "Getting Started example failed: #{inspect(reason)}"
  end

IO.puts("      Agent: #{result.agent_id}")
IO.puts("      Declared model: #{result.model}")
IO.puts("      Prompt roles: #{inspect(Enum.map(result.messages, & &1.role))}")
IO.puts("      Available operations: #{inspect(result.operations)}")
IO.puts("      Preflight diagnostics: #{length(result.diagnostics)}")
IO.puts("[4/4] Final answer: #{result.answer}")

IO.puts("""

Next:
  Read examples/getting_started/lib/agent.ex and copy its basic shape.
  Run mix test --only example:getting_started to see the behavior check.
  Open examples/getting_started/getting_started.livemd for the guided walkthrough.
  Continue with examples/support_agent to add a tool and an approval path.
""")
