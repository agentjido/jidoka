defmodule JidokaExample.AshAgent.Domain do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(JidokaExample.AshAgent.Resources.Customer)
  end
end
