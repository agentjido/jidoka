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

defmodule Jidoka.ImportTest.Support.ExportSpecModule do
  @moduledoc false

  def spec do
    Jidoka.Agent.Spec.new!(
      id: "export_spec_module",
      instructions: "Export this module.",
      model: %{provider: :test, id: "model"}
    )
  end
end

defmodule Jidoka.ImportTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Import.AgentDocument
  alias Jidoka.Import.Normalize
  alias Jidoka.ImportTest.Support.{EchoAction, EchoControl, ExportSpecModule}

  test "import normalization covers scalar, list, and metadata boundaries" do
    assert Normalize.stringify_keys(%{1 => %{ok: true}, outer: [%{inner: :value}]}) == %{
             "outer" => [%{"inner" => :value}],
             1 => %{"ok" => true}
           }

    assert Normalize.tool_entries(%{actions: [:one]}, :actions, :action) == [:one]
    assert Normalize.tool_entries(%{action: :one}, :actions, :action) == [:one]
    assert Normalize.first_value(%{}, [:missing]) == []
    assert Normalize.reverse_result({:ok, [1, 2]}) == {:ok, [2, 1]}
    assert Normalize.reverse_result({:error, :bad}) == {:error, :bad}

    assert Normalize.name(:valid_name) == {:ok, "valid_name"}
    assert Normalize.name(" valid_name ") == {:ok, "valid_name"}
    assert Normalize.name("Bad Name") == {:error, {:invalid_lower_snake_name, "Bad Name"}}
    assert Normalize.name(123) == {:error, {:invalid_name, 123}}

    assert Normalize.name_list(nil, :names) == {:ok, []}
    assert Normalize.name_list(:one, :names) == {:ok, ["one"]}

    assert Normalize.name_list([:one, "Bad Name"], :names) ==
             {:error, {:names, {:invalid_lower_snake_name, "Bad Name"}}}

    assert Normalize.string_list(nil, :values) == {:ok, []}
    assert Normalize.string_list(:one, :values) == {:ok, ["one"]}
    assert Normalize.string(:value) == {:ok, "value"}
    assert Normalize.string(" value ") == {:ok, "value"}
    assert Normalize.string(" ") == {:error, {:invalid_empty_string, " "}}
    assert Normalize.string(123) == {:error, {:invalid_string, 123}}

    assert Normalize.idempotency(:pure) == {:ok, :pure}
    assert Normalize.idempotency(" UNSAFE_ONCE ") == {:ok, :unsafe_once}
    assert Normalize.idempotency("invalid") == {:error, {:invalid_idempotency, "invalid"}}
    assert Normalize.idempotency(123) == {:error, {:invalid_idempotency, 123}}

    assert Normalize.metadata(%{safe: true}) == {:ok, %{safe: true}}
    assert Normalize.metadata(:invalid) == {:error, {:invalid_metadata, :invalid}}
    assert Normalize.metadata_value(:safe) == "safe"
    assert Normalize.metadata_value({:tuple, 1}) == "{:tuple, 1}"
    assert Normalize.metadata_value(1) == 1
    assert Normalize.reject_nil_values(%{a: 1, b: nil}) == %{a: 1}
  end

  alias Jidoka.Review

  test "round-trips ordered inert extension requests" do
    yaml = """
    agent:
      id: extension_agent
      model:
        provider: test
        id: extension-model
    extensions:
      - id: acme.context
        config:
          template: "$(do-not-run)"
          paths: [lib, test]
      - id: acme.context
        instance_id: acme.context.tests
        mode: automation
        enabled: false
        config:
          command: "rm -rf /not-executed"
    """

    assert {:ok, %Agent.Spec{} = spec} = Jidoka.import(yaml, format: :yaml)

    assert [first, second] = spec.extensions
    assert first.id == "acme.context"
    assert first.config["template"] == "$(do-not-run)"
    assert second.instance_id == "acme.context.tests"
    assert second.mode == :automation
    refute second.enabled

    assert {:ok, json} = Jidoka.export(spec, format: :json)
    assert %{"extensions" => [first_map, second_map]} = Jason.decode!(json)
    assert first_map["id"] == "acme.context"
    assert second_map["instance_id"] == "acme.context.tests"

    assert {:ok, %Agent.Spec{} = imported_again} = Jidoka.import(json, format: :json)
    assert imported_again.extensions == spec.extensions
    assert Jidoka.project(imported_again).extensions == Enum.map(spec.extensions, &Jidoka.Extension.Request.to_map/1)
  end

  test "rejects unsafe or ambiguous extension requests" do
    base = %{
      agent: %{id: "invalid_extension_agent", model: %{provider: :test, id: "model"}}
    }

    for extensions <- [
          [%{id: "notnamespaced"}],
          [%{id: "acme.context", unknown: true}],
          [%{id: "acme.context", config: %{"value" => self()}}],
          [%{id: "acme.context"}, %{id: "acme.context"}]
        ] do
      assert {:error, %Jidoka.Error.ValidationError{}} =
               Jidoka.Import.load(Map.put(base, :extensions, extensions))
    end

    oversized = String.duplicate("x", 65_537)

    assert {:error, %Jidoka.Error.ValidationError{}} =
             Jidoka.Import.load(Map.put(base, :extensions, [%{id: "acme.context", config: %{"value" => oversized}}]))
  end

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

  test "round-trips an inert execution profile and rejects backend controls" do
    yaml = """
    agent:
      id: constrained_agent
      model:
        provider: test
        id: constrained-model
      execution_profile: restricted
    """

    assert {:ok, %Agent.Spec{execution_profile: "restricted"} = spec} =
             Jidoka.import(yaml, format: :yaml)

    assert %{execution_profile: "restricted"} = Jidoka.project(spec)
    assert {:ok, json} = Jidoka.export(spec, format: :json)

    assert %{"agent" => %{"execution_profile" => "restricted"}} = Jason.decode!(json)

    assert {:ok, %Agent.Spec{execution_profile: "restricted"}} =
             Jidoka.import(json, format: :json)

    for invalid <- [42, %{"profile" => "restricted"}, ""] do
      assert {:error,
              %Jidoka.Error.ValidationError{
                details: %{reason: {:invalid_execution_profile, ^invalid}}
              }} =
               Jidoka.Import.load(%{
                 agent: %{
                   id: "invalid_profile_agent",
                   model: %{provider: :test, id: "model"},
                   execution_profile: invalid
                 }
               })
    end

    for key <- ~w(execution_environment adapter backend command image mount network) do
      assert {:error,
              %Jidoka.Error.ValidationError{
                details: %{reason: {:forbidden_execution_profile_keys, [^key]}}
              }} =
               Jidoka.Import.load(%{
                 agent: %{
                   key => "untrusted",
                   id: "forbidden_profile_agent",
                   model: %{provider: :test, id: "model"}
                 }
               })
    end
  end

  test "rejects import documents that exceed parser limits" do
    json =
      Jason.encode!(%{
        agent: %{
          id: "limited_import_agent",
          model: %{provider: :test, id: "limited-model"}
        }
      })

    assert {:error,
            %Jidoka.Error.ValidationError{
              details: %{reason: {:import_too_large, :bytes, actual_bytes, 10}}
            }} = Jidoka.import(json, format: :json, max_import_bytes: 10)

    assert actual_bytes > 10

    nested = Jason.encode!(%{"a" => %{"b" => %{"c" => "d"}}})

    assert {:error,
            %Jidoka.Error.ValidationError{
              details: %{reason: {:import_too_deep, depth, 1}}
            }} = Jidoka.import(nested, format: :json, max_import_depth: 1)

    assert depth > 1

    assert {:error,
            %Jidoka.Error.ValidationError{
              details: %{reason: {:import_too_large, :nodes, node_count, 2}}
            }} = Jidoka.import(json, format: :json, max_import_nodes: 2)

    assert node_count >= 2
  end

  test "YAML merge anchors are disabled unless explicitly enabled" do
    yaml = """
    agent:
      <<: &agent_defaults
        id: import_anchor_agent
        model:
          provider: test
          id: anchor-model
      instructions: Loaded through anchors.
    """

    assert {:error, %Jidoka.Error.ValidationError{}} = Jidoka.import(yaml, format: :yaml)

    assert {:ok, %Agent.Spec{id: "import_anchor_agent"}} =
             Jidoka.import(yaml, format: :yaml, yaml_merge_anchors: true)
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

  test "import raising APIs and invalid top-level data use stable errors" do
    attrs = %{id: "raising_import", model: %{provider: :test, id: "model"}}

    assert %Agent.Spec{id: "raising_import"} = Jidoka.Import.load!(attrs)
    json = Jason.encode!(attrs)
    assert %Agent.Spec{id: "raising_import"} = Jidoka.Import.import!(json)

    assert {:error, %Jidoka.Error.ValidationError{field: :document}} = Jidoka.Import.load(:invalid)

    assert_raise Jidoka.Error.ValidationError, fn -> Jidoka.Import.load!(:invalid) end
    assert_raise Jason.DecodeError, fn -> Jidoka.Import.import!("{") end
    assert {:error, %Jidoka.Error.ValidationError{}} = Jidoka.Import.load(%{unknown: true})
  end

  test "import rejects invalid context, result, and operation references" do
    base = %{agent: %{id: "invalid_refs", model: %{provider: :test, id: "model"}}}

    for agent <- [
          %{id: "invalid_refs", model: %{provider: :test, id: "model"}, context: %{}},
          %{id: "invalid_refs", model: %{provider: :test, id: "model"}, context: 123},
          %{id: "invalid_refs", model: %{provider: :test, id: "model"}, result: %{}},
          %{id: "invalid_refs", model: %{provider: :test, id: "model"}, result: 123}
        ] do
      assert {:error, %Jidoka.Error.ValidationError{}} = Jidoka.Import.load(%{base | agent: agent})
    end

    assert {:error, %Jidoka.Error.ValidationError{}} =
             Jidoka.Import.load(Map.put(base, :operations, [123]))

    schema = Zoi.object(%{answer: Zoi.string()})

    assert {:ok, %Agent.Spec{result: %Agent.Spec.Result{metadata: %{"schema_ref" => "answer"}}}} =
             Jidoka.Import.load(
               %{base | agent: Map.put(base.agent, :result, :answer)},
               registries: %{result_schemas: [answer: schema]}
             )
  end

  test "import tool expansion rejects every invalid source reference form" do
    base = %{agent: %{id: "invalid_tools", model: %{provider: :test, id: "model"}}}

    invalid_tools = [
      %{actions: [%{}]},
      %{actions: [123]},
      %{actions: [String]},
      %{ash_resources: [nil]},
      %{ash_resources: [123]},
      %{browsers: [123]},
      %{browsers: [%{name: "docs", mode: :invalid}]},
      %{mcp_tools: [123]},
      %{catalogs: [nil]},
      %{catalogs: [123]}
    ]

    for tools <- invalid_tools do
      assert {:error, %Jidoka.Error.ValidationError{}} =
               Jidoka.Import.load(Map.put(base, :tools, tools))
    end

    assert {:error, %Jidoka.Error.ValidationError{}} =
             Jidoka.Import.load(Map.put(base, :tools, %{actions: ["bad"]}),
               actions: %{"bad" => String}
             )
  end

  test "import controls reject invalid entries and module references" do
    base = %{agent: %{id: "invalid_controls", model: %{provider: :test, id: "model"}}}

    for controls <- [
          %{inputs: [123]},
          %{operations: [123]},
          %{outputs: [123]},
          %{input: %{control: nil}},
          %{operation: %{control: 123}},
          %{output: %{control: String}}
        ] do
      assert {:error, %Jidoka.Error.ValidationError{}} =
               Jidoka.Import.load(Map.put(base, :controls, controls))
    end
  end

  test "import registries accept aliases, nested maps, lists, and atom-string keys" do
    alias Jidoka.Import.Registry

    registries = [
      actions: %{echo: EchoAction},
      ash_resources: [{"resource", String}],
      controls: %{"echo" => EchoControl},
      catalogs: [catalog: String],
      context_schemas: %{context: Zoi.map()},
      result_schemas: [{"result", Zoi.map()}]
    ]

    assert {:ok, EchoAction} = Registry.fetch(:actions, "echo", action_registry: %{echo: EchoAction})
    assert {:ok, String} = Registry.fetch(:ash_resources, :resource, registries: registries)
    assert {:ok, EchoControl} = Registry.fetch(:controls, :echo, registries: Map.new(registries))
    assert {:ok, String} = Registry.fetch(:catalogs, "catalog", catalog_registry: [catalog: String])
    assert {:ok, _schema} = Registry.fetch(:context_schemas, "context", registries: registries)
    assert {:ok, _schema} = Registry.fetch(:result_schemas, :result, registries: registries)
    assert {:error, {:unknown_registry_ref, :actions, :missing}} = Registry.fetch(:actions, :missing, actions: :invalid)

    assert {:error, {:unknown_registry_ref, :actions, :missing}} =
             Registry.fetch(:actions, :missing, registries: :invalid)
  end

  test "export accepts all public inputs, formats, and portable metadata values" do
    spec =
      Agent.Spec.new!(
        id: "export_boundaries",
        instructions: "Export boundaries.",
        model: %{provider: :test, id: "model"},
        runtime_defaults: %{
          keyword: [one: 1],
          list: [:one, {:two, 2}],
          tuple: {:value, 1},
          struct: ~D[2026-08-20]
        },
        metadata: %{dsl_module: __MODULE__, keep: :yes}
      )

    plan = Jidoka.Turn.Plan.new!(spec)
    assert {:ok, _json} = Jidoka.Export.export(spec)
    assert {:ok, compact_json} = Jidoka.Export.export(plan, format: "json", pretty: false)
    refute compact_json =~ "\n"
    assert {:ok, yaml} = Jidoka.Export.export(ExportSpecModule, format: "yaml")
    assert yaml =~ "export_spec_module"
    assert {:ok, %{"agent" => %{"id" => "export_boundaries"}}} = Jidoka.Export.document(plan)

    assert {:error, {:unsupported_export_format, :toml}} = Jidoka.Export.export(spec, format: :toml)
    assert {:error, {:invalid_export_agent, String}} = Jidoka.Export.export(String)
  end

  test "export uses schema refs from options and result metadata" do
    context_schema = Zoi.object(%{tenant: Zoi.string()})
    result_schema = Zoi.object(%{answer: Zoi.string()})

    result =
      Agent.Spec.Result.new!(
        schema: result_schema,
        max_repairs: 2,
        metadata: %{schema_ref: :answer, extra: [mode: :strict]}
      )

    spec =
      Agent.Spec.new!(
        id: "schema_export_boundaries",
        instructions: "Use schemas.",
        model: %{provider: :test, id: "model"},
        context_schema: context_schema,
        result: result
      )

    assert {:error, {:unexportable_context_schema, :missing_context_schema_ref}} =
             Jidoka.Export.document(spec)

    assert {:ok, document} = Jidoka.Export.document(spec, context_schema_ref: :tenant)
    assert document["agent"]["context"] == %{"ref" => "tenant"}
    assert document["agent"]["result"]["ref"] == "answer"
    assert document["agent"]["result"]["metadata"] == %{"extra" => %{"mode" => "strict"}}
  end
end
