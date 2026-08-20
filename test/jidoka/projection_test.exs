defmodule Jidoka.ProjectionTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Snapshot
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
             execution_profile: nil,
             extensions: [],
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

  test "redacts sensitive keys in generic projections" do
    assert %{
             api_key: "[REDACTED]",
             nested: %{
               "Authorization" => "[REDACTED]",
               "safe" => "visible"
             },
             values: [%{password: "[REDACTED]"}]
           } =
             Jidoka.project(%{
               api_key: "secret-key",
               nested: %{"Authorization" => "Bearer secret-token", "safe" => "visible"},
               values: [%{password: "p4ssw0rd"}]
             })
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
    snapshot = Snapshot.from_turn_state!(state, Turn.Cursor.before_effect(intent))
    schema_version = Snapshot.schema_version()

    assert %{
             schema_version: ^schema_version,
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

  test "dispatches every standalone public data contract to a stable projection" do
    modules = [
      Jidoka.Agent.State,
      Jidoka.Agent.Message,
      Jidoka.Handoff,
      Jidoka.Turn.Cursor,
      Jidoka.Effect.Intent,
      Jidoka.Effect.OperationGroup,
      Jidoka.Effect.OperationRequest,
      Jidoka.Effect.OperationResult,
      Jidoka.Effect.Result,
      Jidoka.ExecutionEnvironment.PolicyRequest,
      Jidoka.ExecutionEnvironment.SecurityProfile,
      Jidoka.ExecutionEnvironment.Binding,
      Jidoka.ExecutionEnvironment.Checkpoint,
      Jidoka.ExecutionEnvironment.EnforcementEvidence,
      Jidoka.ExecutionEnvironment.AdapterCapabilities,
      Jidoka.ExecutionEnvironment.Selection,
      Jidoka.ExecutionEnvironment.Error,
      Jidoka.Memory.Entry,
      Jidoka.Memory.Route,
      Jidoka.Memory.RecallRequest,
      Jidoka.Memory.RecallResult,
      Jidoka.Memory.WriteRequest,
      Jidoka.Memory.WriteResult,
      Jidoka.Session.Data,
      Jidoka.Session.Replay,
      Jidoka.Session.Sequence.Terminal,
      Jidoka.Review.Interrupt,
      Jidoka.Review.Request,
      Jidoka.Review.Response,
      Jidoka.Workflow.Spec,
      Jidoka.Workflow.Step,
      Jidoka.Debug.RequestSummary,
      Jidoka.Debug.ReplayDiagnostics,
      Jidoka.Trace.Policy,
      Jidoka.Eval.Run,
      Jidoka.Event
    ]

    Enum.each(modules, fn module ->
      assert module |> struct() |> Jidoka.project() |> is_map()
    end)
  end

  test "projects agent state, messages, and handoffs through the agent projection" do
    message = Agent.Message.assistant("Ready")
    state = %Agent.State{messages: [message], metadata: %{owner: "test"}}

    handoff =
      struct(Jidoka.Handoff,
        id: "handoff-1",
        conversation_id: "conversation-1",
        from_agent: :source,
        to_agent: Agent,
        to_agent_id: "target",
        context: %{tenant: "acme"},
        metadata: %{reason: "specialist"}
      )

    assert %{messages: [%{content: "Ready"}], metadata: %{owner: "test"}} = Jidoka.project(state)
    assert %{content: "Ready"} = Jidoka.project(message)

    assert %{
             id: "handoff-1",
             to_agent: "Jidoka.Agent",
             context: %{tenant: "acme"},
             metadata: %{reason: "specialist"}
           } = Jidoka.project(handoff)
  end

  test "projects standalone agent-spec, decision, state, and sequence contracts" do
    spec_modules = [
      Agent.Spec.Generation,
      Agent.Spec.Result,
      Agent.Spec.Memory,
      Agent.Spec.Operation,
      Agent.Spec.Controls
    ]

    for module <- spec_modules do
      assert module |> struct() |> Jidoka.project() |> is_map()
    end

    for value <- [
          Agent.Spec.Controls.Input.new!(control: SupportControl),
          Agent.Spec.Controls.Output.new!(control: SupportControl),
          Agent.Spec.Controls.Operation.new!(control: SupportControl)
        ] do
      assert value |> Jidoka.project() |> is_map()
    end

    %Turn.State{} =
      state =
      Agent.Spec.new!(id: "projection-state", instructions: "Project.", model: %{provider: :test, id: "model"})
      |> Turn.Plan.new!()
      |> then(fn plan ->
        request = Turn.Request.new!(input: "project")
        Turn.State.new!(plan: plan, request: request, agent_state: request.agent_state)
      end)

    assert %{status: :running} = Jidoka.project(state)
    assert %{type: :final} = Jidoka.project(Effect.LLMDecision.final("done"))

    result = Turn.Result.from_turn_state!(%Turn.State{state | status: :finished, result: "done"})
    step = Jidoka.Session.Sequence.Step.new!(index: 1, request: state.request, result: result)
    assert %{index: 1} = Jidoka.project(step)
  end
end
