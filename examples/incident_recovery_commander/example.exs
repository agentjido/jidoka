Code.require_file(Path.expand("../loader.exs", __DIR__))

IO.puts("[setup] Loading the Durable Incident Recovery Commander...")
JidokaExamples.Loader.load!(__DIR__)

alias JidokaExamples.IncidentRecoveryCommander.Scenario

run! = fn label, fun ->
  IO.puts("\n#{label}")

  case fun.() do
    {:ok, result} -> result
    {:error, reason} -> raise "Incident commander example failed: #{inspect(reason)}"
  end
end

command =
  run!.(
    "[1/3] Run five parallel operations, restart the durable store, and apply two approvals.",
    &Scenario.command/0
  )

IO.puts("      Initial completed operations: #{command.initial.completed_operation_count}")
IO.puts("      Durable continuations: #{length(command.initial.continuation_descriptors)}")
IO.puts("      Approval order: #{Enum.join(command.approval_order, " -> ")}")
IO.puts("      External action counts: #{inspect(command.counts)}")
IO.puts("      Session revision: #{command.completed_session.revision}")
IO.puts("      Replay events: #{length(command.replay.timeline)}")
IO.puts("      Trace entries: #{command.trace.entry_count}")
IO.puts("      Final status: #{command.value.status}")
IO.puts("      Answer: #{command.answer}")

stream =
  run!.("[2/3] Stream a final incident brief with thinking and content deltas.", fn ->
    Scenario.stream_brief()
  end)

IO.puts("      Thinking: #{stream.thinking}")
IO.puts("      Brief: #{stream.text}")
IO.puts("      Terminal events: #{stream.terminal_event_count}")

cancellation =
  run!.("[3/3] Cancel an active incident drill and keep typed terminal evidence.", fn ->
    Scenario.cancellation_drill()
  end)

IO.puts("      Reason: #{cancellation.cancellation.reason}")
IO.puts("      Forced: #{cancellation.cancellation.forced?}")
IO.puts("      Capability still alive: #{cancellation.capability_alive?}")
IO.puts("      Terminal events: #{cancellation.terminal_event_count}")

IO.puts("""

Next:
  Read examples/incident_recovery_commander/README.md for the architecture.
  Run mix test --only example:incident_recovery_commander for the full proof.
  Open incident_recovery_commander.livemd for the guided walkthrough.
""")
