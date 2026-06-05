defmodule Jidoka.Agent.DslSectionsTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Dsl.Sections

  test "agent section declares the expected Spark entity shape" do
    section = Sections.Agent.section()
    [entity] = section.entities

    assert section.name == :jidoka
    assert section.top_level?
    assert section.singleton_entity_keys == [:agent]
    assert entity.name == :agent
    assert entity.target == Jidoka.Agent.Dsl.Agent
    assert entity.args == [:id]
    assert Keyword.has_key?(entity.schema, :model)
    assert Keyword.has_key?(entity.schema, :generation)
    assert Keyword.has_key?(entity.schema, :context)
  end

  test "tools section declares tool source entities" do
    section = Sections.Tools.section()
    entities = Map.new(section.entities, &{&1.name, &1})

    assert section.name == :tools

    assert entities.action.target == Jidoka.Agent.Dsl.Tool
    assert entities.action.args == [:module]
    assert get_in(entities.action.schema, [:module, :type]) == :atom

    assert entities.ash_resource.target == Jidoka.Agent.Dsl.AshResource
    assert entities.ash_resource.args == [:resource]
    assert get_in(entities.ash_resource.schema, [:actions, :default]) == []

    assert entities.browser.target == Jidoka.Agent.Dsl.Browser
    assert entities.browser.args == [:name]
    assert get_in(entities.browser.schema, [:mode, :default]) == :read_only

    assert entities.mcp_tools.target == Jidoka.Agent.Dsl.MCPTools
    assert entities.mcp_tools.args == []
    assert get_in(entities.mcp_tools.schema, [:endpoint, :required])

    assert entities.skill.target == Jidoka.Agent.Dsl.SkillRef
    assert entities.skill.args == [:skill]

    assert entities.load_path.target == Jidoka.Agent.Dsl.SkillPath
    assert entities.load_path.args == [:path]

    assert entities.subagent.target == Jidoka.Agent.Dsl.Subagent
    assert entities.subagent.args == [:agent]
    assert get_in(entities.subagent.schema, [:timeout, :default]) == 30_000

    assert entities.handoff.target == Jidoka.Agent.Dsl.Handoff
    assert entities.handoff.args == [:agent]
    assert get_in(entities.handoff.schema, [:target, :default]) == :auto

    assert entities.workflow.target == Jidoka.Agent.Dsl.Workflow
    assert entities.workflow.args == [:workflow]
    assert get_in(entities.workflow.schema, [:async, :default]) == false
    assert get_in(entities.workflow.schema, [:result, :default]) == :output
  end

  test "controls section declares runtime and operation control entities" do
    section = Sections.Controls.section()
    entities = Map.new(section.entities, &{&1.name, &1})

    assert section.name == :controls
    assert section.singleton_entity_keys == [:max_turns, :timeout]

    assert entities.max_turns.target == Jidoka.Agent.Dsl.MaxTurnsControl
    assert entities.timeout.target == Jidoka.Agent.Dsl.TimeoutControl

    assert entities.input.target == Jidoka.Agent.Dsl.InputControl
    assert entities.input.args == [:control]

    assert entities.output.target == Jidoka.Agent.Dsl.OutputControl
    assert entities.output.args == [:control]
    refute Map.has_key?(entities, :result)

    assert entities.operation.target == Jidoka.Agent.Dsl.OperationControl
    assert entities.operation.args == [:control]
    assert get_in(entities.operation.schema, [:control, :type]) == :atom
    assert get_in(entities.operation.schema, [:when, :as]) == :match
  end
end
