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

  test "tools section declares action entities" do
    section = Sections.Tools.section()
    [entity] = section.entities

    assert section.name == :tools
    assert entity.name == :action
    assert entity.target == Jidoka.Agent.Dsl.Tool
    assert entity.args == [:module]
    assert get_in(entity.schema, [:module, :type]) == :atom
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
