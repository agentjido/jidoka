defmodule JidokaExamples.WarrantyClaim.Scenario do
  @moduledoc false

  alias Jidoka.ContentPart
  alias JidokaExamples.WarrantyClaim.Agent
  alias JidokaExamples.WarrantyClaim.Instructions
  alias JidokaExamples.WarrantyClaim.ScriptedLLM

  @yaml_path Path.expand("../agent.yaml", __DIR__)
  @claim_photo_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

  def run(opts) do
    opts = Keyword.drop(opts, [:credential_ref])

    with {:ok, result} <- execute(opts),
         {:ok, parity?} <- authoring_parity() do
      {:ok,
       %{
         answer: result.content,
         decision: result.value,
         evidence: %{
           authoring_parity: parity?,
           fallback_model: ScriptedLLM.fallback(),
           llm_effects: count_results(result, :llm),
           result_repairs: count_events(result, :result_repair_requested)
         },
         input_parts: Enum.map(claim_input(), &Jidoka.project/1),
         model_attempts: model_attempts(result),
         output_parts: Jidoka.project(result.parts),
         resolved_instructions: resolved_instructions(result)
       }}
    end
  end

  def execute(opts \\ []) do
    observer = Keyword.get(opts, :observer)
    claim_id = Keyword.get(opts, :claim_id, "CLM-2048")

    context = %{
      claim_id: claim_id,
      plan: Keyword.get(opts, :plan, :premium),
      region: Keyword.get(opts, :region, "US"),
      tenant_id: Keyword.get(opts, :tenant_id, "northwind")
    }

    Agent.run_turn(claim_input(claim_id),
      context: context,
      instructions: Instructions,
      llm: ScriptedLLM.capability(claim_id, observer),
      model_policy: model_policy(observer),
      request_id: Keyword.get(opts, :request_id, "warranty-claim-demo")
    )
  end

  def claim_input(claim_id \\ "CLM-2048") do
    [
      ContentPart.text(
        "Claim #{claim_id}: The screen cracked after one accidental drop. Review the photo and receipt."
      ),
      ContentPart.image({:data, Base.decode64!(@claim_photo_base64)},
        media_type: "image/png",
        filename: "#{claim_id}-damage.png",
        metadata: %{view: :front}
      ),
      ContentPart.document({:file_id, "receipt-#{claim_id}"},
        media_type: "application/pdf",
        filename: "#{claim_id}-receipt.pdf",
        metadata: %{kind: :proof_of_purchase}
      )
    ]
  end

  def imported_spec do
    @yaml_path
    |> File.read!()
    |> Jidoka.import(
      format: :yaml,
      context_schemas: %{"warranty_context" => Agent.context_schema()},
      result_schemas: %{"warranty_result" => Agent.result_schema()}
    )
  end

  def authoring_parity do
    with {:ok, imported} <- imported_spec() do
      {:ok, semantic_projection(imported) == semantic_projection(Agent.spec())}
    end
  end

  def semantic_projection(spec) do
    spec
    |> Jidoka.project()
    |> Map.drop([:metadata])
    |> update_in([:result, :metadata], fn _metadata -> %{} end)
  end

  defp model_policy(observer) do
    [
      models: [
        %{provider: :openai, id: "warranty-vision-primary"},
        %{provider: :anthropic, id: "warranty-vision-fallback"}
      ],
      retry: [max_attempts: 2, backoff: [type: :fixed, min: 5, max: 5]],
      sleep: fn delay -> notify(observer, {:warranty_model_backoff, delay}) end
    ]
  end

  defp model_attempts(result) do
    result.events
    |> Enum.filter(&(&1.event == :capability_call_completed and &1.effect_kind == :llm))
    |> Enum.map(& &1.data.model_attempts)
  end

  defp resolved_instructions(result) do
    result.metadata.debug.prompt.messages
    |> Enum.find(&(&1.role == :system))
    |> Map.fetch!(:content)
  end

  defp count_results(result, kind) do
    Enum.count(result.journal.results, fn {_id, effect} -> effect.kind == kind end)
  end

  defp count_events(result, event), do: Enum.count(result.events, &(&1.event == event))

  defp notify(observer, message) when is_pid(observer), do: send(observer, message)
  defp notify(_observer, _message), do: :ok
end
