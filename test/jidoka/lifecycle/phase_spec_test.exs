defmodule JidokaTest.Lifecycle.PhaseSpecTest do
  use ExUnit.Case, async: true

  alias Jidoka.Lifecycle.{Phase, PhaseSpec, State}

  test "before specs compile into phases that update agent and action" do
    spec =
      PhaseSpec.before(:example_before, :example, fn :agent, :action ->
        {:ok, :updated_agent, :updated_action}
      end)

    assert %Phase{name: :example_before, stage: :before, feature: :example} = phase = PhaseSpec.compile!(spec)

    assert %State{agent: :updated_agent, action: :updated_action} =
             Phase.run(phase, State.new!(agent: :agent, action: :action))
  end

  test "after specs compile into phases that update agent and directives" do
    spec =
      PhaseSpec.after_phase(:example_after, :example, fn :agent, :action, [:directive] ->
        {:ok, :updated_agent, [:updated_directive]}
      end)

    phase = PhaseSpec.compile!(spec)

    assert %State{agent: :updated_agent, directives: [:updated_directive]} =
             Phase.run(phase, State.new!(agent: :agent, action: :action, directives: [:directive]))
  end

  test "feature phase specs halt when the wrapped feature returns a non-ok result" do
    spec = PhaseSpec.before(:halting_before, :example, fn _agent, _action -> {:error, :blocked} end)
    phase = PhaseSpec.compile!(spec)

    assert %State{status: :halt, result: {:error, :blocked}} =
             Phase.run(phase, State.new!(agent: :agent, action: :action))
  end

  test "raw specs validate their runner and compile directly" do
    assert {:error, {:invalid_lifecycle_phase_spec_runner, :not_a_function}} =
             PhaseSpec.new(name: :bad, stage: :before, feature: :bad, runner: :not_a_function)

    assert {:ok, %Phase{} = phase} =
             [name: :raw, stage: :before, feature: :raw, runner: fn state -> state end]
             |> PhaseSpec.new!()
             |> PhaseSpec.compile()

    assert %State{agent: :agent} = Phase.run(phase, State.new!(agent: :agent))
  end
end
