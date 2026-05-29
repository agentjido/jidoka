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
end

defmodule Jidoka.Golden.DslToSpecTest do
  use ExUnit.Case, async: true

  alias Jidoka.GoldenTest.Support.{MinimalAgent, TimeAgent}

  test "minimal DSL agent compiles to the expected Agent.Spec projection" do
    assert spec_projection(MinimalAgent.spec()) == %{
             id: "golden_minimal_agent",
             instructions: Jidoka.Agent.default_instructions(),
             model: "test:golden-minimal-model",
             generation: %{
               params: %{temperature: 0.0, max_tokens: 500},
               provider_options: %{},
               extra: %{}
             },
             context_schema?: false,
             operations: [],
             runtime_defaults: %{},
             metadata: %{
               "context_schema?" => false,
               "jido_agent" => true
             }
           }
  end

  test "tool DSL agent compiles to the expected Agent.Spec projection" do
    assert spec_projection(TimeAgent.spec()) == %{
             id: "golden_time_agent",
             instructions: "Call local_time when asked for the time.",
             model: "test:golden-tool-model",
             generation: %{
               params: %{temperature: 0.0, max_tokens: 64},
               provider_options: %{},
               extra: %{}
             },
             context_schema?: true,
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
             runtime_defaults: %{},
             metadata: %{
               "context_schema?" => true,
               "jido_agent" => true
             }
           }
  end

  test "turn plans remain executable data compiled from Agent.Spec" do
    plan = Jidoka.plan!(TimeAgent.spec())

    assert %{
             spec_id: "golden_time_agent",
             workflow_profile: :tool_loop,
             max_model_turns: 8,
             phases: [
               :assemble_prompt,
               :plan_model_effect,
               :apply_model_result,
               :plan_operation_effects,
               :apply_operation_results
             ],
             metadata: %{}
           } == plan_projection(plan)
  end

  defp spec_projection(spec) do
    %{
      id: spec.id,
      instructions: spec.instructions,
      model: Jidoka.Config.model_ref(spec.model),
      generation: %{
        params: spec.generation.params,
        provider_options: spec.generation.provider_options,
        extra: spec.generation.extra
      },
      context_schema?: not is_nil(spec.context_schema),
      operations: Enum.map(spec.operations, &operation_projection/1),
      runtime_defaults: spec.runtime_defaults,
      metadata: Map.take(spec.metadata, ["context_schema?", "jido_agent"])
    }
  end

  defp operation_projection(operation) do
    %{
      name: operation.name,
      description: operation.description,
      idempotency: operation.idempotency,
      metadata: %{
        "runtime" => operation.metadata["runtime"],
        "action" => operation.metadata["action"],
        "parameters_schema?" => is_map(operation.metadata["parameters_schema"])
      }
    }
  end

  defp plan_projection(plan) do
    %{
      spec_id: plan.spec.id,
      workflow_profile: plan.workflow_profile,
      max_model_turns: plan.max_model_turns,
      phases: plan.phases,
      metadata: plan.metadata
    }
  end
end
