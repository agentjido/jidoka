defmodule JidokaExample.KitchenSinkAgentFlowTest do
  use ExUnit.Case, async: true

  alias Jidoka.Effect
  alias Jidoka.Turn
  alias JidokaExample.KitchenSinkAgent.Agent
  alias JidokaExample.KitchenSinkAgent.MCP.LocalClient
  alias JidokaExample.MemoryAgent.Memory

  setup do
    conversation_id = "kitchen-flow-#{System.unique_integer([:positive])}"
    Jidoka.reset_handoff(conversation_id)
    {:ok, conversation_id: conversation_id}
  end

  test "kitchen sink exercises delegated V1 parity surfaces in one agent loop", %{
    conversation_id: conversation_id
  } do
    memory_store = Memory.store()

    request =
      Turn.Request.new!(
        input: "Run the parity showcase.",
        context: %{
          tenant: "demo",
          channel: "test",
          session_id: conversation_id,
          surface: "ex_unit",
          example: "kitchen_sink_agent"
        }
      )

    llm = scripted_llm()

    assert {:ok, %Turn.Result{} = result} =
             Agent.run_turn(request,
               llm: llm,
               operation_context: %{
                 mcp_client: LocalClient,
                 memory_store: memory_store,
                 parent_context: request.context,
                 subagent_llm: llm
               }
             )

    operations = Map.new(result.agent_state.operation_results, &{&1.operation, &1.output})

    assert get(operations["showcase_policy_lookup"], :policy) =~ "Kitchen Sink"
    assert get(get(operations["mcp_showcase_notes"], :result), :note) =~ "MCP operation source"
    assert get(get(operations["evidence_specialist"], :value), :answer) =~ "subagent"
    assert get(get(operations["refund_specialist"], :handoff), :conversation_id) == conversation_id
    assert get(get(operations["build_feature_summary"], :output), :feature_count) == 5

    assert %{
             agent: JidokaExample.ApprovalAgent.Agent,
             agent_id: agent_id
           } = Jidoka.handoff_owner(conversation_id)

    assert agent_id == "#{conversation_id}:refund_specialist"

    assert get(result.value, :summary) =~ "parity"
    assert Enum.any?(get(result.value, :features), &(get(&1, :name) == "workflow"))
  end

  defp scripted_llm do
    fn %Effect.Intent{payload: payload}, %Effect.Journal{} = journal ->
      case {payload.agent_id, count_results(journal, :llm)} do
        {"kitchen_sink_agent", 0} ->
          {:ok,
           %{
             type: :operation,
             name: "showcase_policy_lookup",
             arguments: %{"topic" => "parity"}
           }}

        {"kitchen_sink_agent", 1} ->
          {:ok,
           %{
             type: :operation,
             name: "mcp_showcase_notes",
             arguments: %{"topic" => "parity"}
           }}

        {"kitchen_sink_agent", 2} ->
          {:ok,
           %{
             type: :operation,
             name: "evidence_specialist",
             arguments: %{"task" => "Identify the evidence for subagent parity."}
           }}

        {"kitchen_sink_agent", 3} ->
          {:ok,
           %{
             type: :operation,
             name: "refund_specialist",
             arguments: %{
               "message" => "Own future refund follow-up.",
               "summary" => "The user is exploring Jidoka V2 parity.",
               "reason" => "handoff_parity_demo"
             }
           }}

        {"kitchen_sink_agent", 4} ->
          {:ok,
           %{
             type: :operation,
             name: "build_feature_summary",
             arguments: %{"features" => ["skill", "mcp", "subagent", "handoff", "workflow"]}
           }}

        {"kitchen_sink_agent", 5} ->
          {:ok,
           %{
             type: :final,
             content: "Kitchen Sink parity surfaces ran.",
             result: %{
               summary: "Kitchen Sink parity surfaces ran.",
               features: [
                 %{name: "skill", evidence: "showcase_policy_lookup returned policy data"},
                 %{name: "mcp", evidence: "mcp_showcase_notes returned MCP data"},
                 %{name: "subagent", evidence: "evidence_specialist returned child output"},
                 %{name: "handoff", evidence: "refund_specialist recorded ownership"},
                 %{name: "workflow", evidence: "build_feature_summary returned deterministic output"}
               ],
               sources: [],
               next_steps: ["Inspect operation results."]
             }
           }}

        {"kitchen_sink_evidence_agent", 0} ->
          {:ok,
           %{
             type: :final,
             content: "The subagent result is available to the parent.",
             result: %{
               answer: "subagent parity is demonstrated by a child Jidoka turn",
               assumptions: [],
               next_check: nil
             }
           }}
      end
    end
  end

  defp count_results(%Effect.Journal{results: results}, kind) do
    results
    |> Map.values()
    |> Enum.count(&(&1.kind == kind))
  end

  defp get(map, key, default \\ nil)
  defp get(%{} = map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp get(_map, _key, default), do: default
end
