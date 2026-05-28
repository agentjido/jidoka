defmodule JidokaExamples.Delegation.BillingSpecialist do
  use Jidoka.Agent

  agent :example_billing_specialist do
    model :fast
    instructions "Continue billing conversations after ownership is transferred."
  end
end
