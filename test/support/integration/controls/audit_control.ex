defmodule Jidoka.IntegrationSupport.AuditControl do
  @moduledoc false

  use Jidoka.Control, name: "audit_control"

  @impl true
  def call(_operation), do: :cont
end
