defmodule Jidoka.Policy.RestrictedV01ContractTest do
  use ExUnit.Case, async: true

  alias Jidoka.Policy.Decision
  alias Jidoka.Policy.Gate
  alias Jidoka.Policy.Request

  test "policy decisions represent allow, deny, consent-required, and unsupported" do
    assert :allow in Decision.outcomes()
    assert :deny in Decision.outcomes()
    assert :consent_required in Decision.outcomes()
    assert :unsupported in Decision.outcomes()

    Enum.each([:allow, :deny, :consent_required, :unsupported], fn outcome ->
      assert {:ok, %Decision{outcome: ^outcome}} =
               Decision.new(outcome: outcome, rule_id: "host.#{outcome}")
    end)
  end

  test "bounded unknown policy evidence does not grant authority" do
    assert {:ok, decision} =
             Decision.new(
               outcome: :deny,
               rule_id: "host.unknown",
               evidence: %{"future_field" => %{"note" => "ignored"}}
             )

    assert decision.outcome == :deny
    assert decision.evidence["future_field"]["note"] == "ignored"
  end

  test "gate check fails closed for consent-required and unsupported" do
    request = Request.new!(effect_class: :llm, action: "model.invoke", request_id: "req")

    consent = fn _request, _context ->
      {:ok, Decision.new!(outcome: :consent_required, rule_id: "host.consent", reason: :boundary)}
    end

    unsupported = fn _request, _context ->
      {:ok, Decision.new!(outcome: :unsupported, rule_id: "host.unsupported", reason: :feature)}
    end

    assert {:error, {:policy_consent_required, :boundary}} = Gate.check(request, consent, [])
    assert {:error, {:policy_unsupported, :feature}} = Gate.check(request, unsupported, [])
  end
end
