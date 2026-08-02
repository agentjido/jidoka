Code.require_file(Path.expand("../loader.exs", __DIR__))

IO.puts("[setup] Loading the Support Agent, action, control, and scripted model...")
JidokaExamples.Loader.load!(__DIR__)

alias JidokaExamples.SupportAgent.Scenario

Application.put_env(
  :jidoka,
  :snapshot_signing_secret,
  "support command snapshot secret is at least thirty-two bytes"
)

IO.puts("[setup] Using a deterministic local snapshot secret for this command only.")
IO.puts("[1/5] Sending: Check order A1001 and tell me what to do next.")
IO.puts("[2/5] The scripted model will request lookup_order. The control will allow it.")

result =
  case Scenario.run([]) do
    {:ok, result} -> result
    {:error, reason} -> raise "Support Agent example failed: #{inspect(reason)}"
  end

[operation] = result.operations

IO.puts("      Operation: #{operation.operation} #{inspect(operation.arguments)}")
IO.puts("      Observation status: #{operation.output["status"]}")
IO.puts("[3/5] Final answer: #{result.answer}")

IO.puts("[4/5] Run the protected path and serialize the paused turn outside its process.")

review =
  case Scenario.review_and_resume() do
    {:ok, report} -> report
    {:error, reason} -> raise "Support Agent review example failed: #{inspect(reason)}"
  end

IO.puts("      Review operation: #{review.review.operation}")
IO.puts("      Snapshot schema: #{review.schema_version}")
IO.puts("      Serialized size: #{review.serialized_bytes} bytes")
IO.puts("[5/5] Approve the serialized snapshot and run the action exactly #{review.operation_calls} time.")
IO.puts("      Resumed answer: #{review.answer}")

IO.puts("""

Next:
  Read examples/support_agent/lib/agent.ex for the application definition.
  Run mix test --only example:support_agent for approval and error paths.
  Open examples/support_agent/support_agent.livemd for the guided walkthrough.
""")
