defmodule Jidoka.WorkflowSpikeTest do
  use JidokaTest.Support.Case, async: false

  @moduletag :capture_log

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Runic.Directive.ExecuteRunnable
  alias Jido.Runic.Introspection
  alias Jido.Runic.Strategy
  alias JidokaTest.WorkflowSpike
  alias JidokaTest.WorkflowSpike.{AddAmount, AgentServerAgent}
  alias Runic.Workflow
  alias Runic.Workflow.Invokable

  describe "direct Runic execution" do
    test "runs a Jidoka.Action-backed pipeline end-to-end" do
      productions =
        WorkflowSpike.pipeline_workflow()
        |> Workflow.react_until_satisfied(%{value: 5})
        |> Workflow.raw_productions()

      assert %{value: 12} in productions
    end

    test "observes failed action nodes without producing output" do
      workflow =
        WorkflowSpike.failing_workflow()
        |> Workflow.react_until_satisfied(%{reason: "boom"})

      assert Workflow.raw_productions(workflow) == []
    end
  end

  describe "Jido.Runic.Strategy command loop" do
    test "runs a Jidoka.Action-backed pipeline through ExecuteRunnable directives" do
      agent = make_agent(WorkflowSpike.pipeline_workflow())

      {agent, directives} = feed(agent, %{value: 5})
      {agent, final_directives} = drain_strategy(agent, directives)

      assert get_strat(agent).status == :success
      assert %{value: 12} in Workflow.raw_productions(get_strat(agent).workflow)

      assert Enum.any?(final_directives, fn
               %Jido.Agent.Directive.Emit{signal: %{type: "runic.workflow.production", data: %{value: 12}}} -> true
               _ -> false
             end)
    end

    test "surfaces failed action nodes as failed runnables and failed strategy state" do
      agent = make_agent(WorkflowSpike.failing_workflow())

      {agent, [%ExecuteRunnable{} = directive]} = feed(agent, %{reason: "boom"})
      executed = execute_directive(directive)

      assert executed.status == :failed
      assert Exception.message(executed.error) == "boom"

      {agent, _directives} = apply_result(agent, executed)

      assert get_strat(agent).status == :failure
      assert get_strat(agent).pending == %{}
    end
  end

  describe "AgentServer integration" do
    test "runs the strategy-backed workflow through AgentServer directive execution" do
      jido_name = :"jidoka_workflow_spike_#{System.unique_integer([:positive])}"
      {:ok, jido_pid} = Jido.start_link(name: jido_name)
      on_exit(fn -> stop_if_alive(jido_pid, &Supervisor.stop/1) end)

      {:ok, pid} =
        Jido.AgentServer.start_link(
          agent: AgentServerAgent,
          id: "jidoka-workflow-spike-#{System.unique_integer([:positive])}",
          jido: jido_name,
          debug: true
        )

      on_exit(fn -> stop_if_alive(pid, &GenServer.stop/1) end)

      signal =
        Jido.Signal.new!(
          "runic.feed",
          %{data: %{value: 5}},
          source: "/jidoka/workflow_spike"
        )

      assert :ok = Jido.AgentServer.cast(pid, signal)
      assert {:ok, %{status: :completed}} = Jido.AgentServer.await_completion(pid, timeout: 1_000)

      {:ok, server_state} = Jido.AgentServer.state(pid)
      strat = StratState.get(server_state.agent)

      assert strat.status == :success
      assert %{value: 12} in Workflow.raw_productions(strat.workflow)
    end
  end

  describe "introspection" do
    test "exposes enough graph structure for a future Jidoka.inspect_workflow/1" do
      workflow = WorkflowSpike.pipeline_workflow()

      node_map = Introspection.node_map(workflow)
      graph = Introspection.workflow_graph(workflow)
      summary = Introspection.execution_summary(workflow)

      assert Map.keys(node_map) |> Enum.sort() == [:add_amount, :double_value]
      assert node_map.add_amount.action_mod == AddAmount
      assert node_map.add_amount.inputs == [value: [type: :integer, doc: "Current workflow value"]]

      assert Enum.count(graph.nodes) == 2
      assert Enum.count(graph.edges) >= 1
      assert Enum.any?(graph.edges, &(&1.label in [:connects_to, :flow]))

      assert summary.total_nodes == 2
      assert summary.productions == 0
    end
  end

  defp make_agent(workflow) do
    agent = %Jido.Agent{
      id: "jidoka-workflow-spike-#{System.unique_integer([:positive])}",
      name: "jidoka_workflow_spike",
      description: "Jidoka workflow spike test agent",
      schema: [],
      state: %{}
    }

    {agent, []} = Strategy.init(agent, %{strategy_opts: [workflow: workflow]})
    agent
  end

  defp get_strat(agent), do: StratState.get(agent)

  defp feed(agent, data) do
    instruction = %Jido.Instruction{action: :runic_feed_signal, params: %{data: data}}
    Strategy.cmd(agent, [instruction], %{strategy_opts: []})
  end

  defp apply_result(agent, runnable) do
    instruction = %Jido.Instruction{action: :runic_apply_result, params: %{runnable: runnable}}
    Strategy.cmd(agent, [instruction], %{strategy_opts: []})
  end

  defp execute_directive(%ExecuteRunnable{runnable: runnable}) do
    Invokable.execute(runnable.node, runnable)
  end

  defp drain_strategy(agent, []), do: {agent, []}

  defp drain_strategy(agent, [%ExecuteRunnable{} = directive | rest]) do
    directive
    |> execute_directive()
    |> then(fn runnable -> apply_result(agent, runnable) end)
    |> then(fn {agent, next_directives} ->
      {agent, emitted} = drain_strategy(agent, rest ++ next_directives)
      {agent, emitted}
    end)
  end

  defp drain_strategy(agent, [directive | rest]) do
    {agent, emitted} = drain_strategy(agent, rest)
    {agent, [directive | emitted]}
  end

  defp stop_if_alive(pid, stop_fun) do
    if Process.alive?(pid), do: stop_fun.(pid)
  catch
    :exit, _reason -> :ok
  end
end
