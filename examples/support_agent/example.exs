Code.require_file(Path.expand("../loader.exs", __DIR__))

IO.puts("[setup] Loading the Support Agent, action, control, and scripted model...")
JidokaExamples.Loader.load!(__DIR__)

alias JidokaExamples.SupportAgent.Scenario

IO.puts("[1/3] Sending: Check order A1001 and tell me what to do next.")
IO.puts("[2/3] The scripted model will request lookup_order. The control will allow it.")

result =
  case Scenario.run([]) do
    {:ok, result} -> result
    {:error, reason} -> raise "Support Agent example failed: #{inspect(reason)}"
  end

[operation] = result.operations

IO.puts("      Operation: #{operation.operation} #{inspect(operation.arguments)}")
IO.puts("      Observation status: #{operation.output["status"]}")
IO.puts("[3/3] Final answer: #{result.answer}")

IO.puts("""

Next:
  Read examples/support_agent/lib/agent.ex for the application definition.
  Run mix test --only example:support_agent for approval and error paths.
  Open examples/support_agent/support_agent.livemd for the guided walkthrough.
""")
