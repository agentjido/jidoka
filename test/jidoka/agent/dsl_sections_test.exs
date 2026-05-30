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

  test "controls section declares operation control entities" do
    section = Sections.Controls.section()
    [entity] = section.entities

    assert section.name == :controls
    assert entity.name == :operation
    assert entity.target == Jidoka.Agent.Dsl.OperationControl
    assert entity.args == [:control]
    assert get_in(entity.schema, [:control, :type]) == :atom
    assert get_in(entity.schema, [:when, :as]) == :match
  end
end
