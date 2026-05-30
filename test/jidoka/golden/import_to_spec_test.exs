defmodule Jidoka.ImportGoldenTest.Support.LocalTimeAction do
  use Jidoka.Action,
    name: "local_time",
    description: "Returns a deterministic local time for imported agents.",
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

defmodule Jidoka.ImportGoldenTest.Support.RequireLocalTimeApproval do
  use Jidoka.Control, name: "require_local_time_approval"

  @impl true
  def call(_operation), do: :cont
end

defmodule Jidoka.ImportGoldenTest.Support.TimeAgent do
  use Jidoka.Agent

  agent :import_golden_time_agent do
    model %{provider: :test, id: "import-golden-model"}
    generation %{temperature: 0.0, max_tokens: 64}
    instructions "Call local_time when asked for the time."
    context Zoi.object(%{tenant_id: Zoi.string()})
  end

  tools do
    action Jidoka.ImportGoldenTest.Support.LocalTimeAction
  end

  controls do
    operation Jidoka.ImportGoldenTest.Support.RequireLocalTimeApproval,
      when: [kind: :action, name: :local_time]
  end
end

defmodule Jidoka.Golden.ImportToSpecTest do
  use ExUnit.Case, async: true

  alias Jidoka.ImportGoldenTest.Support.{LocalTimeAction, TimeAgent}

  @context_schema Zoi.object(%{tenant_id: Zoi.string()})

  test "YAML imports compile to the same semantic Agent.Spec projection as DSL" do
    yaml = """
    version: 1
    agent:
      id: import_golden_time_agent
      model:
        provider: test
        id: import-golden-model
      generation:
        temperature: 0.0
        max_tokens: 64
      instructions: Call local_time when asked for the time.
      context:
        ref: tenant_context
    tools:
      actions:
        - local_time
    controls:
      operations:
        - control: require_local_time_approval
          when:
            kind: action
            name: local_time
    """

    assert {:ok, imported_spec} =
             Jidoka.Import.import(yaml,
               format: :yaml,
               registries: registries()
             )

    assert semantic_projection(imported_spec) == semantic_projection(TimeAgent.spec())
  end

  test "JSON imports support the same Phase 1 document shape" do
    json =
      Jason.encode!(%{
        version: 1,
        agent: %{
          id: "import_golden_time_agent",
          model: %{provider: "test", id: "import-golden-model"},
          generation: %{temperature: 0.0, max_tokens: 64},
          instructions: "Call local_time when asked for the time.",
          context: %{ref: "tenant_context"}
        },
        tools: %{actions: ["local_time"]},
        controls: %{
          operations: [
            %{
              control: "require_local_time_approval",
              when: %{kind: "action", name: "local_time"}
            }
          ]
        }
      })

    assert {:ok, imported_spec} =
             Jidoka.Import.import(json,
               format: :json,
               registries: registries()
             )

    assert semantic_projection(imported_spec) == semantic_projection(TimeAgent.spec())
  end

  defp registries do
    %{
      actions: %{"local_time" => LocalTimeAction},
      controls: %{
        "require_local_time_approval" => Jidoka.ImportGoldenTest.Support.RequireLocalTimeApproval
      },
      context_schemas: %{"tenant_context" => @context_schema}
    }
  end

  defp semantic_projection(spec) do
    spec
    |> Jidoka.projection()
    |> Map.drop([:metadata])
  end
end
