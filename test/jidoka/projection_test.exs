defmodule Jidoka.ProjectionTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  defmodule SupportControl do
    use Jidoka.Control, name: "support_control"

    @impl true
    def call(_operation), do: :cont
  end

  test "projects specs without raw schemas or LLMDB structs" do
    spec =
      Agent.Spec.new!(
        id: "projection_agent",
        instructions: "Project this spec.",
        model: %{provider: :test, id: "projection-model"},
        context_schema: Zoi.object(%{tenant_id: Zoi.string()}),
        operations: [
          %{
            name: "lookup",
            description: "Lookup a value.",
            metadata: %{
              "runtime" => "test",
              "parameters_schema" => %{type: "object"}
            }
          }
        ],
        controls: %{
          operations: [
            %{
              control: SupportControl,
              match: %{kind: "action", name: "lookup"}
            }
          ]
        },
        metadata: %{
          "context_schema?" => true,
          "dsl_module" => "Hidden.Module",
          "owner" => "unit"
        }
      )

    assert Jidoka.project(spec) == %{
             id: "projection_agent",
             instructions: "Project this spec.",
             model: "test:projection-model",
             generation: %{
               params: %{temperature: 0.0, max_tokens: 500},
               provider_options: %{},
               extra: %{}
             },
             context_schema?: true,
             result: nil,
             memory: nil,
             operations: [
               %{
                 name: "lookup",
                 description: "Lookup a value.",
                 idempotency: :idempotent,
                 metadata: %{
                   "runtime" => "test",
                   "parameters_schema?" => true
                 }
               }
             ],
             controls: %{
               max_turns: nil,
               timeout_ms: nil,
               inputs: [],
               outputs: [],
               operations: [
                 %{
                   control: "support_control",
                   module: "Jidoka.ProjectionTest.SupportControl",
                   match: %{kind: :action, name: "lookup"},
                   metadata: %{}
                 }
               ],
               metadata: %{}
             },
             runtime_defaults: %{},
             metadata: %{
               "context_schema?" => true,
               "owner" => "unit"
             }
           }
  end

  test "projects journals in deterministic intent/result order" do
    first = Effect.Intent.new(:llm, %{request_id: "turn_1"}, id: "a", idempotency_key: "k1")
    second = Effect.Intent.new(:operation, %{name: "lookup"}, id: "b", idempotency_key: "k2")

    journal =
      Effect.Journal.new!()
      |> Effect.Journal.put_intent(second)
      |> Effect.Journal.put_intent(first)
      |> Effect.Journal.put_result(Effect.Result.ok(second, %{value: 2}))
      |> Effect.Journal.put_result(Effect.Result.ok(first, %{value: 1}))

    assert %{
             intents: [
               %{id: "a", kind: :llm, idempotency_key: "k1"},
               %{id: "b", kind: :operation, idempotency_key: "k2"}
             ],
             results: [
               %{intent_id: "a", kind: :llm, output: %{value: 1}},
               %{intent_id: "b", kind: :operation, output: %{value: 2}}
             ]
           } = Jidoka.project(journal)
  end

  test "projects structured result contracts without exposing raw Zoi schema data" do
    spec =
      Agent.Spec.new!(
        id: "structured_projection_agent",
        instructions: "Project a result schema.",
        model: %{provider: :test, id: "projection-model"},
        result: [
          schema: Zoi.object(%{answer: Zoi.string()}),
          max_repairs: 2,
          metadata: %{owner: "unit"}
        ]
      )

    assert %{result: %{schema?: true, max_repairs: 2, metadata: %{owner: "unit"}}} =
             Jidoka.project(spec)
  end

  test "summarizes raw LLMDB models and Zoi schemas in nested projection data" do
    {:ok, model} = Jidoka.Config.normalize_model_spec(%{provider: :test, id: "nested-model"})

    assert Jidoka.project(%{
             model: model,
             schema: Zoi.object(%{tenant_id: Zoi.string()})
           }) == %{
             model: "test:nested-model",
             schema: %{schema?: true}
           }
  end

  test "projects snapshots through cursor and turn state projections" do
    spec =
      Agent.Spec.new!(
        id: "snapshot_projection_agent",
        instructions: "Snapshot projection.",
        model: %{provider: :test, id: "projection-model"}
      )

    plan = Turn.Plan.new!(spec)
    request = Turn.Request.new!(input: "Hello")

    %Turn.State{} =
      state =
      Turn.State.new!(
        spec: spec,
        plan: plan,
        request: request,
        agent_state: request.agent_state
      )

    intent = Effect.Intent.new(:llm, %{request_id: request.request_id}, id: "llm:1")
    state = Turn.State.set_pending_effects(state, [intent])
    snapshot = AgentSnapshot.from_turn_state!(state, Turn.Cursor.before_effect(intent))

    assert %{
             schema_version: 1,
             agent_id: "snapshot_projection_agent",
             cursor: %{
               phase: :before_effect,
               metadata: %{"effect_id" => "llm:1", "effect_kind" => :llm}
             },
             turn_state: %{
               spec_id: "snapshot_projection_agent",
               pending_effects: [%{id: "llm:1", kind: :llm}],
               plan: %{spec_id: "snapshot_projection_agent"}
             }
           } = Jidoka.project(snapshot)
  end
end
