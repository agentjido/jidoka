defmodule Jidoka.GoldenTest.Support.LocalTimeAction do
  use Jidoka.Action,
    name: "local_time",
    description: "Returns a deterministic local time for a city.",
    schema:
      Zoi.object(%{
        city: Zoi.string() |> Zoi.default("Chicago")
      })

  @impl true
  def run(params, _context) do
    city = Map.get(params, :city) || Map.get(params, "city") || "Chicago"
    {:ok, %{city: city, time: "09:30"}}
  end
end

defmodule Jidoka.GoldenTest.Support.MinimalAgent do
  use Jidoka.Agent

  agent :golden_minimal_agent do
    model %{provider: :test, id: "golden-minimal-model"}
  end
end

defmodule Jidoka.GoldenTest.Support.RequireLocalTimeApproval do
  use Jidoka.Control, name: "require_local_time_approval"

  @impl true
  def call(_operation), do: :cont
end

defmodule Jidoka.GoldenTest.Support.TimeAgent do
  use Jidoka.Agent

  agent :golden_time_agent do
    model %{provider: :test, id: "golden-tool-model"}
    generation %{temperature: 0.0, max_tokens: 64}
    instructions "Call local_time when asked for the time."
    context Zoi.object(%{tenant_id: Zoi.string()})
  end

  tools do
    action Jidoka.GoldenTest.Support.LocalTimeAction
  end

  controls do
    operation Jidoka.GoldenTest.Support.RequireLocalTimeApproval,
      when: [kind: :action, name: :local_time]
  end
end

defmodule Jidoka.Golden.DslToSpecTest do
  use ExUnit.Case, async: true

  alias Jidoka.GoldenTest.Support.{MinimalAgent, TimeAgent}

  test "minimal DSL agent compiles to the expected Agent.Spec projection" do
    assert Jidoka.project(MinimalAgent.spec()) == %{
             id: "golden_minimal_agent",
             instructions: Jidoka.Agent.default_instructions(),
             model: "test:golden-minimal-model",
             generation: %{
               params: %{temperature: 0.0, max_tokens: 500},
               provider_options: %{},
               extra: %{}
             },
             context_schema?: false,
             result: nil,
             memory: nil,
             operations: [],
             controls: %{
               max_turns: nil,
               timeout_ms: nil,
               inputs: [],
               outputs: [],
               operations: [],
               metadata: %{}
             },
             runtime_defaults: %{},
             metadata: %{
               "context_schema?" => false,
               "jido_agent" => true,
               "result_schema?" => false
             }
           }
  end

  test "tool DSL agent compiles to the expected Agent.Spec projection" do
    assert Jidoka.project(TimeAgent.spec()) == %{
             id: "golden_time_agent",
             instructions: "Call local_time when asked for the time.",
             model: "test:golden-tool-model",
             generation: %{
               params: %{temperature: 0.0, max_tokens: 64},
               provider_options: %{},
               extra: %{}
             },
             context_schema?: true,
             result: nil,
             memory: nil,
             operations: [
               %{
                 name: "local_time",
                 description: "Returns a deterministic local time for a city.",
                 idempotency: :idempotent,
                 metadata: %{
                   "runtime" => "jido_action",
                   "action" => "Jidoka.GoldenTest.Support.LocalTimeAction",
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
                   control: "require_local_time_approval",
                   module: "Jidoka.GoldenTest.Support.RequireLocalTimeApproval",
                   match: %{kind: :action, name: "local_time"},
                   metadata: %{}
                 }
               ],
               metadata: %{}
             },
             runtime_defaults: %{},
             metadata: %{
               "context_schema?" => true,
               "jido_agent" => true,
               "result_schema?" => false
             }
           }
  end

  test "turn plans remain executable data compiled from Agent.Spec" do
    plan = Jidoka.plan!(TimeAgent.spec())

    assert %{
             spec_id: "golden_time_agent",
             workflow_profile: :tool_loop,
             max_model_turns: 8,
             timeout_ms: 30_000,
             phases: [
               :assemble_prompt,
               :plan_model_effect,
               :apply_model_result,
               :plan_operation_effects,
               :apply_operation_results
             ],
             metadata: %{}
           } == Jidoka.project(plan)
  end
end
