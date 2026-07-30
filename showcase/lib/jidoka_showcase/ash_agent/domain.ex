defmodule JidokaShowcase.AshAgent.Domain do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(JidokaShowcase.AshAgent.Resources.Customer)
  end
end
