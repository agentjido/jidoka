defmodule JidokaExample.KitchenSinkAgent.Controls.AllowSpecialistHandoff do
  @moduledoc false

  use Jidoka.Control, name: "allow_specialist_handoff"

  @impl true
  def call(%{boundary: :operation, kind: :handoff, operation: "refund_specialist"}), do: :allow
  def call(_operation), do: :allow
end
