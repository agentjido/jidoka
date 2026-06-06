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
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Import.AgentDocument
  alias Jidoka.ImportTest.Support.{EchoAction, EchoControl}
  alias Jidoka.Review

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

  test "approval policies export and import as portable operation data" do
    spec =
      Agent.Spec.new!(
        id: "approval_export_agent",
        model: %{provider: :test, id: "approval-model"},
        instructions: "Use approval-protected operations.",
        operations: [
          Operation.new!(
            name: "refund_order",
            description: "Refunds an order.",
            idempotency: :unsafe_once,
            approval: %{
              reason: "refund_review",
              message: "Review the refund.",
              ttl_ms: 30_000,
              metadata: %{risk: :high}
            }
          )
        ]
      )

    assert {:ok, json} = Jidoka.export(spec, format: :json)
    assert {:ok, %Agent.Spec{} = imported} = Jidoka.import(json)

    assert [
             %Operation{
               name: "refund_order",
               idempotency: :unsafe_once,
               approval: %Review.Policy{
                 reason: "refund_review",
                 message: "Review the refund.",
                 ttl_ms: 30_000,
                 metadata: %{"risk" => "high"}
               }
             }
           ] = imported.operations
  end

  test "imports memory policy data" do
    assert {:ok, %Agent.Spec{memory: memory}} =
             Jidoka.Import.load(%{
               agent: %{
                 id: "import_memory_agent",
                 model: %{provider: :test, id: "memory-model"},
                 memory: %{scope: "session", max_entries: "3"}
               }
             })

    assert %Agent.Spec.Memory{scope: :session, max_entries: 3} = memory
  end

  test "import documents enforce the current document version" do
    assert AgentDocument.version() == 1

    assert {:error,
            %Jidoka.Error.ValidationError{
              details: %{reason: {:unsupported_import_document_version, 2, 1}}
            }} =
             Jidoka.Import.load(%{
               version: 2,
               agent: %{id: "future_import_agent", model: %{provider: :test, id: "model"}}
             })
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

  test "imports structured result schema refs through an explicit registry" do
    result_schema =
      Zoi.object(%{
        answer: Zoi.string(),
        score: Zoi.integer()
      })

    assert {:ok, %Agent.Spec{} = spec} =
             Jidoka.Import.load(
               %{
                 agent: %{
                   id: "import_result_agent",
                   model: %{provider: :test, id: "result-model"},
                   result: %{
                     ref: "answer_result",
                     max_repairs: 2
                   }
                 }
               },
               result_schemas: %{"answer_result" => result_schema}
             )

    assert %Agent.Spec.Result{max_repairs: 2, metadata: %{"schema_ref" => "answer_result"}} =
             spec.result

    assert spec.metadata["result_schema?"]

    assert {:ok, %{answer: "Ada", score: 10}} =
             Agent.Spec.Result.validate(spec.result, %{"answer" => "Ada", "score" => 10})
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
                   output: %{control: "echo_control"}
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

    assert [%Agent.Spec.Controls.Output{control: EchoControl}] = spec.controls.outputs
  end

  test "rejects legacy result control import keys" do
    for legacy_key <- [:result, :results] do
      assert {:error,
              %Jidoka.Error.ValidationError{
                details: %{reason: {:unsupported_control_key, ^legacy_key, _replacement}}
              }} =
               Jidoka.Import.load(
                 %{
                   agent: %{
                     id: "import_legacy_#{legacy_key}_control_agent",
                     model: %{provider: :test, id: "control-model"}
                   },
                   controls: %{
                     legacy_key => %{control: "echo_control"}
                   }
                 },
                 controls: %{"echo_control" => EchoControl}
               )
    end
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

  test "exports portable JSON that imports back into an equivalent spec" do
    spec =
      Jidoka.agent!(
        id: "export_round_trip_agent",
        model: %{provider: :test, id: "export-model"},
        instructions: "Export this agent.",
        generation: %{params: %{temperature: 0.2, max_tokens: 64}},
        memory: %{scope: :session, max_entries: 4},
        operations: [
          %{
            name: "lookup",
            description: "Looks up a value.",
            idempotency: :pure,
            metadata: %{kind: :tool, owner: "tests"}
          }
        ],
        controls: %{
          max_turns: 3,
          timeout_ms: 1_000,
          operation: %{
            control: EchoControl,
            match: %{kind: :tool, name: "lookup"}
          }
        }
      )

    assert {:ok, json} = Jidoka.export(spec, format: :json)

    assert {:ok, %Agent.Spec{} = imported} =
             Jidoka.import(json, format: :json, controls: %{"echo_control" => EchoControl})

    assert imported.id == spec.id
    assert imported.instructions == spec.instructions
    assert Jidoka.Config.model_ref(imported.model) == "test:export-model"
    assert imported.memory.scope == :session
    assert [%{name: "lookup", idempotency: :pure}] = imported.operations
    assert imported.operations |> hd() |> Operation.kind() == :tool
    assert imported.controls.max_turns == 3
    assert [%{control: EchoControl}] = imported.controls.operations
  end

  test "exports portable YAML and requires refs for runtime-only schemas" do
    assert {:ok, yaml} =
             Jidoka.export(
               [
                 id: "export_yaml_agent",
                 model: %{provider: :test, id: "yaml-model"},
                 instructions: "Export me."
               ],
               format: :yaml
             )

    assert yaml =~ "export_yaml_agent"
    assert {:ok, %Agent.Spec{id: "export_yaml_agent"}} = Jidoka.import(yaml, format: :yaml)

    schema = Zoi.object(%{answer: Zoi.string()})

    spec =
      Jidoka.agent!(
        id: "export_schema_agent",
        model: %{provider: :test, id: "schema-model"},
        instructions: "Needs refs.",
        result: schema
      )

    assert {:error, {:unexportable_result_schema, :missing_result_schema_ref}} =
             Jidoka.export(spec)

    assert {:ok, json} = Jidoka.export(spec, result_schema_ref: "answer_result")

    assert {:ok, %Agent.Spec{result: result}} =
             Jidoka.import(json,
               format: :json,
               result_schemas: %{"answer_result" => schema}
             )

    assert %Agent.Spec.Result{metadata: %{"schema_ref" => "answer_result"}} = result
  end
end
