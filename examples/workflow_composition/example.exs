Code.require_file(Path.expand("../loader.exs", __DIR__))

IO.puts("[setup] Loading the Workflow Composition agent and its deterministic scenarios...")
JidokaExamples.Loader.load!(__DIR__)

alias Jidoka.Workflow.{Background, Scheduler}
alias JidokaExamples.WorkflowComposition.Scenario

runner = JidokaExamples.WorkflowComposition.ExampleRunner
scheduler = JidokaExamples.WorkflowComposition.ExampleScheduler
now = ~U[2026-08-01 12:00:00Z]

run! = fn label, fun ->
  IO.puts("\n#{label}")

  case fun.() do
    {:ok, result} -> result
    {:error, reason} -> raise "Workflow Composition example failed: #{inspect(reason)}"
  end
end

direct =
  run!.(
    "[1/4] Run the fulfillment graph directly, then expose the same graph as one agent tool.",
    fn -> Scenario.direct_and_agent() end
  )

IO.puts("      Conditional route: #{direct.direct_output.route}")
IO.puts("      Parallel item total: #{direct.direct_output.total}")
IO.puts("      Inventory attempts: #{direct.direct_output.reservation_attempts}")
IO.puts("      Bounded loop shipped: #{Enum.join(direct.direct_output.shipped, ", ")}")
IO.puts("      Dynamic work created: #{length(direct.direct_output.created_work)} item")
IO.puts("      Direct and agent results match: #{direct.parity?}")
IO.puts("      Agent answer: #{direct.agent_answer}")

IO.puts("\n[2/4] Start the supervised background runner and schedule service.")

children = [
  {Background, name: runner},
  {Scheduler, name: scheduler, runner: runner, auto_schedule: false, clock: fn -> now end}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
IO.puts("      Runner: #{inspect(runner)}")
IO.puts("      Scheduler: #{inspect(scheduler)}")

background =
  run!.(
    "[3/4] Submit the same graph as a background run and reconnect by its stable ID.",
    fn -> Scenario.background(runner) end
  )

IO.puts("      Run ID: #{background.run.id}")
IO.puts("      Status: #{background.run.status}")
IO.puts("      Persisted lifecycle events: #{length(background.events)}")
IO.puts("      Output route: #{background.run.output.route}")

scheduled =
  run!.(
    "[4/4] Trigger a one-time schedule that creates another normal background run.",
    fn -> Scenario.scheduled(scheduler, runner, now) end
  )

IO.puts("      Schedule ID: #{scheduled.schedule.id}")
IO.puts("      Trigger status: #{scheduled.trigger.status}")
IO.puts("      Created run ID: #{scheduled.trigger.run_id}")
IO.puts("      Run status: #{scheduled.run.status}")

IO.puts("""

The same workflow graph now works in four forms:
  direct call -> one agent tool -> background run -> scheduled background run

Next:
  Read examples/workflow_composition/lib/fulfillment_workflow.ex for the graph.
  Run mix test --only example:workflow_composition for the behavior proofs.
  Open examples/workflow_composition/workflow_composition.livemd for the guided walkthrough.
""")
