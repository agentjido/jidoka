defmodule JidokaExample.DebugAgent.Actions.InspectAgent do
  @moduledoc false

  use Jidoka.Action,
    name: "inspect_agent",
    description: "Returns Jidoka.inspect/1 data for one example agent.",
    schema:
      Zoi.object(%{
        target: Zoi.string() |> Zoi.default("support")
      })

  alias JidokaExample.DebugAgent.Targets

  @impl true
  def run(params, _context) do
    params
    |> get(:target, "support")
    |> Targets.inspect_target()
  end

  defp get(params, key, default),
    do: Map.get(params, key, Map.get(params, Atom.to_string(key), default))
end
