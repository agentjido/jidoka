defmodule JidokaExamples.WarrantyClaim.ScriptedLLM do
  @moduledoc false

  alias Jidoka.Config
  alias Jidoka.ContentPart
  alias Jidoka.Schema

  @primary "openai:warranty-vision-primary"
  @fallback "anthropic:warranty-vision-fallback"

  def primary, do: @primary
  def fallback, do: @fallback

  def capability(claim_id, observer \\ nil) do
    fn intent, journal, _context ->
      model = Config.model_ref(intent.payload.model)
      phase = if llm_result_count(journal) == 0, do: :initial, else: :repair
      notify(observer, {:warranty_model_called, model, phase})

      case model do
        @primary -> {:error, :timeout}
        @fallback -> fallback_result(claim_id, phase, intent.payload.prompt)
        unsupported -> {:error, {:unsupported_demo_model, unsupported}}
      end
    end
  end

  defp fallback_result(claim_id, :initial, _prompt) do
    {:ok,
     %{
       type: :final,
       content: "The claim appears eligible, but the confidence value needs repair.",
       result: %{
         claim_id: claim_id,
         confidence: "high",
         damage_type: :accidental,
         decision: :approve,
         explanation: "The premium plan and supplied evidence support the claim.",
         required_actions: ["Confirm the product serial number."],
         warranty_eligible: true
       }
     }}
  end

  defp fallback_result(claim_id, :repair, prompt) do
    if repair_requested?(prompt) do
      repaired_result(claim_id)
    else
      {:error, :missing_result_repair_feedback}
    end
  end

  defp repaired_result(claim_id) do
    content = "Approve claim #{claim_id}. Confirm the serial number and issue the replacement."

    {:ok,
     %{
       type: :final,
       content: content,
       parts: [
         ContentPart.text(content),
         ContentPart.document({:file_id, "warranty-summary-#{claim_id}"},
           media_type: "application/pdf",
           filename: "#{claim_id}-decision.pdf",
           metadata: %{kind: :warranty_decision}
         )
       ],
       result: %{
         claim_id: claim_id,
         confidence: 0.94,
         damage_type: :accidental,
         decision: :approve,
         explanation: "The premium plan covers accidental damage, and the claim includes a receipt and product photo.",
         required_actions: ["Confirm the product serial number.", "Issue a replacement device."],
         warranty_eligible: true
       }
     }}
  end

  defp repair_requested?(prompt) do
    prompt
    |> Schema.get_key(:messages, [])
    |> Enum.any?(fn message ->
      message
      |> Schema.get_key(:metadata, %{})
      |> Schema.get_key(:jidoka_result_repair, false)
    end)
  end

  defp llm_result_count(journal) do
    Enum.count(journal.results, fn {_id, result} -> result.kind == :llm end)
  end

  defp notify(observer, message) when is_pid(observer), do: send(observer, message)
  defp notify(_observer, _message), do: :ok
end
