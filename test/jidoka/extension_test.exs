defmodule Jidoka.ExtensionTest.Support.EmptyExtension do
  use Jidoka.Extension

  @impl true
  def name, do: :empty
end

defmodule Jidoka.ExtensionTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Event
  alias Jidoka.Extension.Patch
  alias Jidoka.ExtensionTest.Support.EmptyExtension
  alias Jidoka.Extensions
  alias Jidoka.Extensions.Trace
  alias Jidoka.Runtime.LocalOperations

  import Jidoka.TestSupport, only: [count_results: 2]

  test "extension behaviour supplies narrow defaults" do
    assert EmptyExtension.name() == :empty
    assert EmptyExtension.dsl_sections() == []
    assert EmptyExtension.verifiers() == []
    assert EmptyExtension.workflow_steps(%{}) == []
    assert EmptyExtension.runtime_requirements(%{}) == []
    assert EmptyExtension.events() == []
    assert {:ok, %Patch{}} = EmptyExtension.spec_patch(%{}, %{})
  end

  test "trace extension appends typed sequence-stable events" do
    events =
      []
      |> append_event(:prompt_assembled,
        agent_id: "agent_1",
        request_id: "turn_1",
        loop_index: 0
      )
      |> append_event(:effect_planned,
        agent_id: "agent_1",
        request_id: "turn_1",
        loop_index: 0,
        effect_id: "llm:1",
        effect_kind: :llm
      )

    assert [
             %Event{
               seq: 0,
               event: :prompt_assembled,
               category: :workflow,
               phase: :assemble_prompt
             },
             %Event{
               seq: 1,
               event: :effect_planned,
               category: :effect,
               effect_id: "llm:1",
               effect_kind: :llm
             }
           ] = events

    assert [
             %{seq: 0, event: :prompt_assembled, agent_id: "agent_1"},
             %{seq: 1, event: :effect_planned, effect_id: "llm:1"}
           ] = Trace.timeline(events)
  end

  test "built-in trace extension advertises its event names" do
    assert [Trace] = Extensions.builtins()

    assert [
             %{
               name: :trace,
               events: events,
               dsl_sections: 0,
               verifiers: []
             }
           ] = Extensions.describe()

    assert :trace = Trace.name()
    assert :prompt_assembled in events
    assert :effect_planned in events
    assert :effect_started in events
    assert :effect_replayed in events
    assert :capability_call_started in events
    assert :capability_call_completed in events
    assert :capability_call_failed in events
  end

  test "trace extension records a real tool-loop turn timeline" do
    spec =
      Agent.Spec.new!(
        id: "trace_tool_agent",
        instructions: "Use lookup when useful, then answer.",
        operations: [Operation.new!(name: "lookup", description: "Looks up a value.")],
        runtime_defaults: %{max_model_turns: 3}
      )

    llm = fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 -> {:ok, %{type: :operation, name: "lookup", arguments: %{"id" => "A-1"}}}
        1 -> {:ok, %{type: :final, content: "Lookup result is ready."}}
      end
    end

    operations =
      LocalOperations.operations(%{
        lookup: fn intent, _journal ->
          {:ok, %{id: intent.payload.arguments["id"], status: "ready"}}
        end
      })

    assert {:ok, result} = Jidoka.turn(spec, "Lookup A-1", llm: llm, operations: operations)

    timeline = Trace.timeline(result.events)

    assert Enum.map(timeline, & &1.event) == [
             :prompt_assembled,
             :effect_planned,
             :effect_started,
             :capability_call_started,
             :capability_call_completed,
             :effect_completed,
             :effect_planned,
             :effect_started,
             :capability_call_started,
             :capability_call_completed,
             :effect_completed,
             :operation_observed,
             :prompt_assembled,
             :effect_planned,
             :effect_started,
             :capability_call_started,
             :capability_call_completed,
             :effect_completed,
             :turn_finished
           ]

    assert Enum.map(timeline, & &1.seq) == Enum.to_list(0..18)

    assert [
             %{event: :effect_planned, effect_kind: :operation, operation: "lookup"},
             %{event: :effect_started, effect_kind: :operation, operation: "lookup"},
             %{event: :capability_call_started, effect_kind: :operation, operation: "lookup"},
             %{event: :capability_call_completed, effect_kind: :operation, operation: "lookup"},
             %{event: :effect_completed, effect_kind: :operation, operation: "lookup"}
           ] = Enum.filter(timeline, &(&1[:effect_kind] == :operation))
  end

  defp append_event(events, event, attrs) do
    events ++ [Event.build(event, events, attrs)]
  end
end
