Code.require_file(Path.expand("../loader.exs", __DIR__))

IO.puts("[setup] Loading the Durable Refund agent and six deterministic scenarios...")
JidokaExamples.Loader.load!(__DIR__)

alias JidokaExamples.DurableRefund.Scenario

run! = fn label, fun ->
  IO.puts("\n#{label}")

  case fun.() do
    {:ok, result} -> result
    {:error, reason} -> raise "Durable Refund example failed: #{inspect(reason)}"
  end
end

stream =
  run!.("[1/6] Stream one asynchronous request and collect its terminal event.", fn ->
    Scenario.async_streaming()
  end)

IO.puts("      Thinking: #{stream.thinking}")
IO.puts("      Streamed answer: #{stream.text}")
IO.puts("      Terminal events: #{length(stream.terminal_events)}")

parallel =
  run!.("[2/6] Run two policy checks together and preserve model order.", fn ->
    Scenario.parallel_operations()
  end)

IO.puts("      Completion order: #{Enum.join(parallel.completion_order, ", ")}")
IO.puts("      Observation order: #{Enum.join(parallel.observation_order, ", ")}")
IO.puts("      Answer: #{parallel.answer}")

cancellation =
  run!.("[3/6] Cancel active model work and wait for typed cancellation evidence.", fn ->
    Scenario.typed_cancellation()
  end)

IO.puts("      Reason: #{cancellation.cancellation.reason}")
IO.puts("      Forced: #{cancellation.cancellation.forced?}")
IO.puts("      Model process still alive: #{cancellation.capability_alive?}")

limits =
  run!.("[4/6] Enforce model-turn, output-token, and capability-time limits.", fn ->
    Scenario.bounded_execution()
  end)

IO.puts("      Output-token limit seen by the model: #{limits.max_tokens}")
IO.puts("      Refund operation calls: #{limits.operation_calls}")

{:error, turn_limit} = limits.turn_result
{:error, capability_timeout} = limits.timeout_result

IO.puts(
  "      Turn limit stopped the run: #{turn_limit.details.reason} " <>
    "(max model turns: #{turn_limit.details.max_model_turns})"
)

IO.puts(
  "      Capability limit stopped the run: #{capability_timeout.details.reason} " <>
    "(timeout: #{capability_timeout.details.timeout_ms} ms)"
)

recovery =
  run!.("[5/6] Stop a worker after the refund result is durable, then recover it.", fn ->
    Scenario.durable_recovery()
  end)

IO.puts("      Refund operation calls after recovery: #{recovery.operation_calls}")
IO.puts("      Recovered session status: #{recovery.session.status}")
IO.puts("      Answer: #{recovery.answer}")

fork =
  run!.("[6/6] Fork one hibernated session and resume both branches independently.", fn ->
    Scenario.safe_fork()
  end)

IO.puts("      Source answer: #{fork.source_answer}")
IO.puts("      Branch answer: #{fork.branch_answer}")
IO.puts("      Branch depth: #{fork.branch.lineage.depth}")
IO.puts("      Source replay status: #{fork.source_replay.status}")
IO.puts("      Replayed events: #{length(fork.source_replay.timeline)}")

IO.puts("""

Next:
  Read examples/durable_refund/lib/scenarios/ in the README order.
  Run mix test --only example:durable_refund for the runtime guarantees.
  Open examples/durable_refund/durable_refund.livemd for the guided walkthrough.
""")
