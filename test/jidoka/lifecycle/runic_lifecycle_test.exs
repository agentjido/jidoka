defmodule JidokaTest.RunicLifecycleTest do
  use JidokaTest.Support.Case, async: false

  alias Jidoka.Lifecycle.{Config, Graph, Phase, Runner, State}
  alias JidokaTest.HookedAgent

  test "builds lifecycle structs through Zoi-backed constructors" do
    assert {:ok, %Config{context: %{tenant: "demo"}}} =
             Config.new(
               hooks: Jidoka.Hooks.default_stage_map(),
               context: %{tenant: "demo"},
               guardrails: Jidoka.Guardrails.default_stage_map(),
               mcp_tools: []
             )

    assert {:ok, %State{action: :start, directives: []}} =
             State.new(agent: :agent, action: :start)

    assert {:ok, %Phase{name: :example, stage: :before}} =
             Phase.new(name: :example, stage: :before, runner: fn state -> state end)

    assert {:error, {:invalid_lifecycle_phase_runner, :not_a_function}} =
             Phase.new(name: :bad, stage: :before, runner: :not_a_function)

    assert {:error, {:invalid_lifecycle_context, :not_a_map}} =
             Config.new(
               hooks: Jidoka.Hooks.default_stage_map(),
               context: :not_a_map,
               guardrails: Jidoka.Guardrails.default_stage_map(),
               mcp_tools: []
             )
  end

  test "runs phase chains through a Runic workflow in declaration order" do
    phases = [
      append_phase(:first),
      append_phase(:second),
      append_phase(:third)
    ]

    state = State.new!(agent: :agent, action: [])

    assert %State{action: [:first, :second, :third]} =
             Runner.run_phases(phases, state, :test_lifecycle_order)

    assert Graph.phase_names(phases) == [:first, :second, :third]
  end

  test "halts subsequent Runic phases after a phase returns a terminal result" do
    phases = [
      append_phase(:first),
      Phase.new!(
        name: :halt,
        stage: :before,
        runner: fn _state -> {:halt, {:error, :blocked}} end
      ),
      append_phase(:unreachable)
    ]

    state = State.new!(agent: :agent, action: [])

    assert %State{status: :halt, result: {:error, :blocked}, action: [:first]} =
             Runner.run_phases(phases, state, :test_lifecycle_halt)
  end

  test "halts a phase chain when a runner returns a raw terminal value" do
    phases = [
      append_phase(:first),
      Phase.new!(
        name: :raw_halt,
        stage: :before,
        runner: fn _state -> :stop_now end
      ),
      append_phase(:unreachable)
    ]

    state = State.new!(agent: :agent, action: [])

    assert %State{status: :halt, result: :stop_now, action: [:first]} =
             Runner.run_phases(phases, state, :test_lifecycle_raw_halt)
  end

  test "reraises phase runner failures instead of hiding them behind Runic state" do
    phases = [
      Phase.new!(
        name: :boom,
        stage: :before,
        runner: fn _state -> raise "phase boom" end
      )
    ]

    state = State.new!(agent: :agent, action: [])

    assert_raise RuntimeError, "phase boom", fn ->
      Runner.run_phases(phases, state, :test_lifecycle_raise)
    end
  end

  test "returns terminal before results exactly and skips later phases" do
    config = lifecycle_config()

    assert {:error, :super_failed} =
             Runner.run_before(__MODULE__, :agent, :action, config, fn _agent, _action ->
               {:error, :super_failed}
             end)
  end

  test "returns terminal after results exactly and skips later phases" do
    config = lifecycle_config()

    assert {:error, :after_failed} =
             Runner.run_after(__MODULE__, :agent, :action, [], config, fn _agent, _action, _directives ->
               {:error, :after_failed}
             end)
  end

  test "generated agent modules do not expose lifecycle helpers as public API" do
    runtime = HookedAgent.runtime_module()

    refute function_exported?(HookedAgent, :lifecycle_graph, 0)
    refute function_exported?(HookedAgent, :lifecycle_phases, 0)
    refute function_exported?(runtime, :lifecycle_graph, 0)
    refute function_exported?(runtime, :lifecycle_phases, 0)
  end

  test "declares the current before and after phase order around ReAct" do
    config = lifecycle_config()

    before_names =
      __MODULE__
      |> Runner.before_phases(config, fn agent, action -> {:ok, agent, action} end)
      |> Graph.phase_names()

    after_names =
      __MODULE__
      |> Runner.after_phases(config, fn agent, _action, directives -> {:ok, agent, directives} end)
      |> Graph.phase_names()

    assert before_names == [
             :jido_ai_before,
             :compaction_before,
             :memory_before,
             :hooks_before,
             :output_before,
             :skills_before,
             :controls_before,
             :mcp_before,
             :subagent_before,
             :handoff_before
           ]

    assert after_names == [
             :jido_ai_after,
             :hooks_after,
             :output_after,
             :controls_after,
             :memory_after,
             :subagent_after,
             :workflow_after,
             :handoff_after
           ]
  end

  test "generated runtime callbacks preserve Jido.AI request tracking and hook behavior" do
    runtime = HookedAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    assert {:ok, agent, {:ai_react_start, params}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start, %{query: "hello", request_id: "req-runic-1", tool_context: %{}}}
             )

    assert params.query == "hello for acme"
    assert get_in(agent.state, [:requests, "req-runic-1", :query]) == "hello"

    agent = Jido.AI.Request.complete_request(agent, "req-runic-1", "done")

    assert {:ok, agent, []} =
             runtime.on_after_cmd(agent, {:ai_react_start, %{request_id: "req-runic-1"}}, [])

    assert Jido.AI.Request.get_result(agent, "req-runic-1") == {:ok, "normalized:done!"}
  end

  defp append_phase(name) do
    Phase.new!(
      name: name,
      stage: :before,
      runner: fn %State{action: action} = state ->
        {:ok, %{state | action: action ++ [name]}}
      end
    )
  end

  defp lifecycle_config do
    Config.new!(
      hooks: Jidoka.Hooks.default_stage_map(),
      context: %{},
      guardrails: Jidoka.Guardrails.default_stage_map(),
      mcp_tools: []
    )
  end
end
