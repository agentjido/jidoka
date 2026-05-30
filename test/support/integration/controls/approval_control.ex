defmodule Jidoka.IntegrationSupport.ApprovalControl do
  @moduledoc false

  use Jidoka.Control, name: "require_approval"

  @impl true
  def call(_operation), do: :cont
end
