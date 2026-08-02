defmodule JidokaExamples.WorkflowCompositionTest do
  use ExUnit.Case, async: false

  alias Jidoka.Workflow.{Background, Run, Scheduler}
  alias JidokaExamples.WorkflowComposition.Scenario

  @moduletag example: :workflow_composition
  @moduletag timeout: 10_000

  @runner __MODULE__.Runner
  @scheduler __MODULE__.Scheduler
  @now ~U[2026-08-01 12:00:00Z]

  setup do
    start_supervised!({Background, name: @runner})

    start_supervised!({Scheduler, name: @scheduler, runner: @runner, auto_schedule: false, clock: fn -> @now end})

    :ok
  end

  @tag :sequential_typed_steps
  @tag :conditional_routing
  @tag :parallel_fan_out
  @tag :bounded_dynamic_loops
  @tag :bounded_step_retry
  @tag :workflow_tool
  test "runs one composed workflow directly and as one agent tool" do
    assert {:ok, report} = Scenario.direct_and_agent(observer: self())

    assert report.parity?
    assert report.agent_output == report.direct_output

    assert report.direct_output == %{
             created_work: [%{index: 99, quantity: 1, sku: "welcome_card", subtotal: 0}],
             reservation_attempts: 2,
             route: :priority,
             shipped: ["starter_kit", "cable", "welcome_card"],
             total: 35
           }

    assert report.agent_answer == "The order workflow completed successfully."
    assert_received {:inventory_reservation_attempt, 1}
    assert_received {:inventory_reservation_attempt, 2}
  end

  @tag :background_runs
  test "submits and reconnects to one background workflow run" do
    assert {:ok, report} =
             Scenario.background(@runner,
               observer: self(),
               run_id: "workflow_composition_background_test"
             )

    assert %Run{status: :completed, workflow_id: "fulfill_order"} = report.run
    assert report.run.output.route == :priority
    assert report.run.output.shipped == ["starter_kit", "cable", "welcome_card"]
    assert report.events != []
    assert Enum.map(report.events, & &1.sequence) == Enum.to_list(1..length(report.events))
  end

  @tag :scheduled_runs
  test "starts one scheduled workflow as a normal background run" do
    assert {:ok, report} =
             Scenario.scheduled(@scheduler, @runner, @now,
               observer: self(),
               schedule_id: "workflow_composition_schedule_test"
             )

    assert report.trigger.status == :started
    assert report.trigger.schedule_id == report.schedule.id
    assert report.run.id == report.trigger.run_id
    assert report.run.status == :completed
    assert report.run.output.reservation_attempts == 2
  end

  @tag :static_multi_agent_workflow
  test "runs two bounded agent nodes through static deterministic edges" do
    assert {:ok, "Approved: Order A1001 is ready for priority fulfillment."} =
             Scenario.static_multi_agent(observer: self())

    assert_receive {:static_agent_node_called, :draft}
    assert_receive {:static_agent_node_called, :review}
    refute_receive {:static_agent_node_called, _stage}
  end
end
