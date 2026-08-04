Code.require_file(Path.expand("../loader.exs", __DIR__))

IO.puts("[setup] Loading the Support Agent, action, control, and scripted model...")
JidokaExamples.Loader.load!(__DIR__)

alias JidokaExamples.SupportAgent.Scenario
alias JidokaExamples.SupportAgent.View

Application.put_env(
  :jidoka,
  :snapshot_signing_secret,
  "support command snapshot secret is at least thirty-two bytes"
)

IO.puts("[setup] Using a deterministic local snapshot secret for this command only.")
IO.puts("[1/6] Sending: Check order A1001 and tell me what to do next.")
IO.puts("[2/6] Input, operation, and output controls will allow the safe path.")

result =
  case Scenario.run([]) do
    {:ok, result} -> result
    {:error, reason} -> raise "Support Agent example failed: #{inspect(reason)}"
  end

[operation] = result.operations

IO.puts("      Operation: #{operation.operation} #{inspect(operation.arguments)}")
IO.puts("      Observation status: #{operation.output["status"]}")
IO.puts("[3/6] Final answer: #{result.answer}")

{:ok, view} = View.initial(%{conversation_id: "order-a1001"})
running_view = View.before_turn(view, "Check order A1001")

turn_result =
  case Scenario.execute() do
    {:ok, turn_result} -> turn_result
    {:error, reason} -> raise "Support Agent view example failed: #{inspect(reason)}"
  end

finished_view = View.after_turn(running_view, {:ok, turn_result})

IO.puts(
  "[4/6] UI projection: #{length(finished_view.visible_messages)} messages, #{length(finished_view.events)} events"
)

IO.puts("[5/6] Run the protected path and serialize the paused turn outside its process.")

review =
  case Scenario.review_and_resume() do
    {:ok, report} -> report
    {:error, reason} -> raise "Support Agent review example failed: #{inspect(reason)}"
  end

IO.puts("      Review operation: #{review.review.operation}")
IO.puts("      Snapshot schema: #{review.schema_version}")
IO.puts("      Serialized size: #{review.serialized_bytes} bytes")
IO.puts("[6/6] Approve the serialized snapshot and run the action exactly #{review.operation_calls} time.")
IO.puts("      Resumed answer: #{review.answer}")

IO.puts("""

Next:
  Read examples/support_agent/lib/agent.ex for the application definition.
  Run mix test --only example:support_agent for approval and error paths.
  Open examples/support_agent/support_agent.livemd for the guided walkthrough.
""")
