defmodule Jidoka.AshJidoContextIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Effect
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  defmodule ContextProbeResource do
    @moduledoc false

    use Ash.Resource,
      domain: Jidoka.AshJidoContextIntegrationTest.TestDomain,
      extensions: [AshJido]

    actions do
      action :context_probe, :map do
        run(fn _input, context ->
          {:ok, %{actor: context.actor, tenant: context.tenant}}
        end)
      end
    end

    jido do
      action(:context_probe, name: "ash_context_probe")
    end
  end

  defmodule TestDomain do
    @moduledoc false

    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(ContextProbeResource)
    end
  end

  defmodule ContextAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :ash_jido_context_agent do
      model %{provider: :test, id: "model"}
      instructions "Use the Ash context probe before answering."
    end

    tools do
      ash_resource ContextProbeResource, actions: [:context_probe]
    end
  end

  test "generated AshJido actions receive actor and tenant through a full turn" do
    actor = %{id: "actor-1"}

    llm = fn _intent, %Effect.Journal{} = journal, _context ->
      case count_results(journal, :llm) do
        0 ->
          {:ok, %{type: :operation, name: "ash_context_probe", arguments: %{}}}

        1 ->
          assert journal.results
                 |> Map.values()
                 |> Enum.any?(&match?(%Effect.Result{kind: :operation}, &1))

          {:ok, %{type: :final, content: "Ash context received."}}
      end
    end

    request =
      Turn.Request.new!(
        input: "Inspect the current Ash actor and tenant.",
        context: %{actor: actor, tenant: "tenant-1"}
      )

    assert {:ok, %Turn.Result{content: "Ash context received."} = result} =
             ContextAgent.run_turn(request, llm: llm)

    assert [
             %Effect.OperationResult{
               operation: "ash_context_probe",
               output: %{
                 "actor" => %{"id" => "actor-1"},
                 "tenant" => "tenant-1"
               }
             }
           ] = result.agent_state.operation_results
  end
end
