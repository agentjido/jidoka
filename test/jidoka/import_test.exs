defmodule Jidoka.ImportTest.Support.EchoAction do
  use Jidoka.Action,
    name: "echo_value",
    description: "Echoes imported values.",
    schema:
      Zoi.object(%{
        value: Zoi.string()
      })

  @impl true
  def run(params, _context) do
    value = Map.get(params, :value) || Map.get(params, "value")
    {:ok, %{value: value}}
  end
end

defmodule Jidoka.ImportTest.Support.EchoControl do
  use Jidoka.Control, name: "echo_control"

  @impl true
  def call(_operation), do: :cont
end

defmodule Jidoka.ImportTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.ImportTest.Support.{EchoAction, EchoControl}

  test "imports the smallest possible agent document with default instructions" do
    assert {:ok, %Agent.Spec{} = spec} =
             Jidoka.Import.load(%{
               id: "import_minimal_agent",
               model: %{provider: :test, id: "minimal-model"}
             })

    assert spec.id == "import_minimal_agent"
    assert spec.instructions == Jidoka.Agent.default_instructions()
    assert Jidoka.Config.model_ref(spec.model) == "test:minimal-model"
    assert spec.operations == []
    assert spec.metadata["source"] == "import"
  end

  test "imports YAML strings and records source metadata" do
    yaml = """
    agent:
      id: import_yaml_agent
      model:
        provider: test
        id: yaml-model
      instructions: Loaded from YAML.
    operations:
      - name: lookup
        description: Looks up a value.
        idempotency: pure
    """

    assert {:ok, %Agent.Spec{} = spec} = Jidoka.Import.import(yaml)

    assert spec.id == "import_yaml_agent"
    assert Jidoka.Config.model_ref(spec.model) == "test:yaml-model"
    assert [%{name: "lookup", idempotency: :pure}] = spec.operations
    assert spec.metadata["source_ref"]["kind"] == "string"
    assert spec.metadata["source_ref"]["format"] == "yaml"
  end

  test "imports action refs through an explicit registry" do
    assert {:ok, %Agent.Spec{} = spec} =
             Jidoka.Import.load(
               %{
                 agent: %{
                   id: "import_tool_agent",
                   model: %{provider: :test, id: "tool-model"},
                   instructions: "Use echo_value."
                 },
                 tools: %{
                   actions: [%{ref: "echo"}]
                 }
               },
               actions: %{"echo" => EchoAction}
             )

    assert [%{name: "echo_value", metadata: %{"runtime" => "jido_action"}}] =
             spec.operations
  end

  test "imports operation controls through an explicit registry" do
    assert {:ok, %Agent.Spec{} = spec} =
             Jidoka.Import.load(
               %{
                 agent: %{
                   id: "import_control_agent",
                   model: %{provider: :test, id: "control-model"},
                   instructions: "Use echo_value."
                 },
                 controls: %{
                   operations: [
                     %{
                       control: "echo_control",
                       when: %{kind: "action", name: "echo_value"}
                     }
                   ]
                 }
               },
               controls: %{"echo_control" => EchoControl}
             )

    assert [
             %Agent.Spec.Controls.Operation{
               control: EchoControl,
               match: %{kind: :action, name: "echo_value"}
             }
           ] = spec.controls.operations
  end

  test "imports planned singular control keys as data aliases" do
    assert {:ok, %Agent.Spec{} = spec} =
             Jidoka.Import.load(
               %{
                 agent: %{
                   id: "import_singular_controls_agent",
                   model: %{provider: :test, id: "control-model"}
                 },
                 controls: %{
                   input: %{control: "echo_control"},
                   operation: %{
                     control: "echo_control",
                     when: %{kind: "action", name: "echo_value"}
                   },
                   result: %{control: "echo_control"}
                 }
               },
               controls: %{"echo_control" => EchoControl}
             )

    assert [%Agent.Spec.Controls.Input{control: EchoControl}] = spec.controls.inputs

    assert [
             %Agent.Spec.Controls.Operation{
               control: EchoControl,
               match: %{kind: :action, name: "echo_value"}
             }
           ] = spec.controls.operations

    assert [%Agent.Spec.Controls.Result{control: EchoControl}] = spec.controls.results
  end

  test "returns validation errors for unknown refs and duplicate operations" do
    assert {:error,
            %Jidoka.Error.ValidationError{
              details: %{reason: {:unknown_registry_ref, :actions, "missing"}}
            }} =
             Jidoka.Import.load(%{
               agent: %{id: "bad_import_agent", model: %{provider: :test, id: "model"}},
               tools: %{actions: ["missing"]}
             })

    assert {:error,
            %Jidoka.Error.ValidationError{
              details: %{reason: {:duplicate_operation, "lookup"}}
            }} =
             Jidoka.Import.load(%{
               agent: %{id: "duplicate_import_agent", model: %{provider: :test, id: "model"}},
               operations: [
                 %{name: "lookup"},
                 %{name: "lookup"}
               ]
             })
  end

  test "does not convert unknown import refs into atoms or modules" do
    assert {:error,
            %Jidoka.Error.ValidationError{
              details: %{reason: {:unknown_registry_ref, :actions, "Elixir.String"}}
            }} =
             Jidoka.Import.load(%{
               agent: %{id: "safe_ref_agent", model: %{provider: :test, id: "model"}},
               tools: %{actions: ["Elixir.String"]}
             })

    assert {:error,
            %Jidoka.Error.ValidationError{
              details: %{reason: {:unknown_registry_ref, :actions, "missing"}}
            }} =
             Jidoka.Import.load(
               %{
                 agent: %{id: "safe_registry_agent", model: %{provider: :test, id: "model"}},
                 tools: %{actions: ["missing"]}
               },
               actions: %{{:tuple_key} => EchoAction}
             )
  end

  test "top-level Jidoka import helper delegates to the importer" do
    json =
      Jason.encode!(%{
        agent: %{
          id: "root_import_agent",
          model: %{provider: "test", id: "root-model"}
        }
      })

    assert {:ok, %Agent.Spec{id: "root_import_agent"} = spec} =
             Jidoka.import(json, format: :json)

    assert Jidoka.Config.model_ref(spec.model) == "test:root-model"
  end
end
