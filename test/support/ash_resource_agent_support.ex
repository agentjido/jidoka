defmodule JidokaTest.Support.AshResourceAgent do
  use Jidoka.Agent

  agent :ash_resource_agent do
    model :fast
    instructions "You can use Ash resource tools."
  end

  capabilities do
    ash_resource JidokaTest.Support.User
  end
end
