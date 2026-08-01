Code.require_file("../../_support/test_helper.exs", __DIR__)
Code.require_file("../../_support/registry.exs", __DIR__)

{:ok, warranty_claim_example} = JidokaExamples.fetch(:warranty_claim)
{:ok, _modules} = JidokaExamples.load(warranty_claim_example)

defmodule JidokaExamples.WarrantyClaim.WarrantyClaimTriageTest do
  use ExUnit.Case, async: true

  alias Jidoka.ContentPart
  alias Jidoka.Schema
  alias Jidoka.Turn
  alias JidokaExamples.WarrantyClaim.Agent
  alias JidokaExamples.WarrantyClaim.Example
  alias JidokaExamples.WarrantyClaim.ScriptedLLM

  @moduletag proof_example: :warranty_claim
  @moduletag timeout: 5_000

  setup_all do
    {:ok, manifest} = JidokaExamples.fetch(:warranty_claim)
    assert manifest.agent == Agent
    %{manifest: manifest}
  end

  @tag proof_case: {:warranty_claim_triage, :equivalent_authoring}
  test "compiles the DSL and YAML definitions to the same semantic spec" do
    assert {:ok, imported} = Example.imported_spec()

    assert Example.semantic_projection(imported) ==
             Example.semantic_projection(Agent.spec())

    assert {:ok, true} = Example.authoring_parity()
  end

  @tag proof_case: {:warranty_claim_triage, :tenant_policy}
  test "validates tenant context and resolves the request policy" do
    assert {:ok, %Turn.Result{} = result} =
             Example.execute(tenant_id: "northwind", region: "US", plan: :premium)

    instructions = system_instructions(result)
    assert instructions =~ Agent.base_instructions()
    assert instructions =~ "Tenant: northwind."
    assert instructions =~ "Apply the United States warranty policy."
    assert instructions =~ "The premium plan covers accidental damage"

    assert {:error, error} = Example.execute(plan: :unknown)
    assert Jidoka.Error.category(error) == :validation
  end

  @tag proof_case: {:warranty_claim_triage, :resilient_typed_decision}
  test "keeps media typed, falls back, repairs once, and returns the typed decision" do
    assert {:ok, %Turn.Result{} = result} = Example.execute(observer: self())

    assert result.value == %{
             claim_id: "CLM-2048",
             confidence: 0.94,
             damage_type: :accidental,
             decision: :approve,
             explanation:
               "The premium plan covers accidental damage, and the claim includes a receipt and product photo.",
             required_actions: ["Confirm the product serial number.", "Issue a replacement device."],
             warranty_eligible: true
           }

    assert [
             %ContentPart{type: :text},
             %ContentPart{type: :document, file_id: "warranty-summary-CLM-2048"}
           ] = result.parts

    assert Enum.count(result.events, &(&1.event == :result_repair_requested)) == 1
    assert Enum.count(result.events, &(&1.event == :result_validated)) == 1

    assert Enum.any?(result.agent_state.messages, fn message ->
             metadata = Schema.get_key(message, :metadata, %{})
             content = Schema.get_key(message, :content, "")

             Schema.get_key(metadata, :jidoka_result_repair) == true and
               String.contains?(content, "confidence")
           end)

    assert model_calls(6) == [
             {ScriptedLLM.primary(), :initial},
             {ScriptedLLM.primary(), :initial},
             {ScriptedLLM.fallback(), :initial},
             {ScriptedLLM.primary(), :repair},
             {ScriptedLLM.primary(), :repair},
             {ScriptedLLM.fallback(), :repair}
           ]

    assert backoffs(2) == [5, 5]

    llm_results =
      result.journal.results
      |> Map.values()
      |> Enum.filter(&(&1.kind == :llm))

    assert length(llm_results) == 2

    Enum.each(llm_results, fn effect ->
      assert [first, second, winner] = effect.metadata.model_attempts
      assert first.model == ScriptedLLM.primary()
      assert first.failure_class == :transient
      assert second.model_attempt == 2
      assert winner.model == ScriptedLLM.fallback()
      assert winner.winner
    end)

    user_content =
      result.metadata.debug.prompt.messages
      |> Enum.find(fn message -> message.role == :user and is_list(message.content) end)
      |> Map.fetch!(:content)

    assert Enum.map(user_content, & &1.type) == [:text, :image, :document]
    assert Enum.at(user_content, 1).source == :data
    assert Enum.at(user_content, 1).byte_size > 0
    assert Enum.at(user_content, 2).source == :file_id
    refute Map.has_key?(Enum.at(user_content, 1), :data)
    refute Map.has_key?(Enum.at(user_content, 2), :file_id)

    assert {:ok, report} = Example.run([])
    assert report.evidence.authoring_parity
    assert report.evidence.llm_effects == 2
    assert report.evidence.result_repairs == 1
    assert report.decision.decision == :approve
    assert Enum.map(report.input_parts, & &1.type) == [:text, :image, :document]
    refute Enum.any?(report.input_parts, &Map.has_key?(&1, :data))
    refute Enum.any?(report.input_parts, &Map.has_key?(&1, :file_id))
  end

  defp system_instructions(result) do
    result.metadata.debug.prompt.messages
    |> Enum.find(&(&1.role == :system))
    |> Map.fetch!(:content)
  end

  defp model_calls(count) do
    Enum.map(1..count, fn _index ->
      assert_receive {:warranty_model_called, model, phase}
      {model, phase}
    end)
  end

  defp backoffs(count) do
    Enum.map(1..count, fn _index ->
      assert_receive {:warranty_model_backoff, delay}
      delay
    end)
  end
end
