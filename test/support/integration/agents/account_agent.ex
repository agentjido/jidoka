defmodule Jidoka.IntegrationSupport.AccountAgent do
  @moduledoc false

  use Jidoka.Agent

  agent :multi_turn_account_agent do
    model %{provider: :test, id: "model"}
    instructions "Use account_lookup before answering account questions."
  end

  tools do
    action Jidoka.IntegrationSupport.AccountLookupAction
  end
end
