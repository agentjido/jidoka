defmodule JidokaExamples.Ash.Accounts do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(JidokaExamples.Ash.User)
  end
end
