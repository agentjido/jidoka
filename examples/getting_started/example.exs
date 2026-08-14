Code.require_file(Path.expand("../loader.exs", __DIR__))

IO.puts("[setup] Loading the smallest Jidoka agent and its deterministic scenario...")
JidokaExamples.Loader.load!(__DIR__)

alias JidokaExamples.GettingStarted.Scenario

IO.puts("[1/5] Compiled one agent with a model and one instruction.")
IO.puts("[2/5] Preflight the first request without calling the model.")
IO.puts("[3/5] Start one session and send two messages.")

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
IO.puts("[4/5] Session: #{result.session_id} · turns: #{result.turn_count}")

Enum.zip(result.inputs, result.answers)
|> Enum.each(fn {input, answer} ->
  IO.puts("      User: #{input}")
  IO.puts("      Assistant: #{answer}")
end)

IO.puts("[5/5] The second answer used the first committed turn.")

IO.puts("""

Next:
  Read examples/getting_started/lib/agent.ex and copy its basic shape.
  Run mix test --only example:getting_started to see the behavior check.
  Open examples/getting_started/getting_started.livemd for the guided walkthrough.
  Continue with examples/support_agent to add a tool and an approval path.
""")
