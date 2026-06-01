defmodule JidokaExample.DebugAgent.Actions.PreflightAgent do
  @moduledoc false

  use Jidoka.Action,
    name: "preflight_agent",
    description: "Runs Jidoka.preflight/3 for one example agent without calling the LLM.",
    schema:
      Zoi.object(%{
        target: Zoi.string() |> Zoi.default("support"),
        prompt: Zoi.string() |> Zoi.nullish()
      })

  alias JidokaExample.DebugAgent.Targets

  @impl true
  def run(params, _context) do
    Targets.preflight_target(get(params, :target, "support"), get(params, :prompt))
  end

  defp get(params, key, default \\ nil),
    do: Map.get(params, key, Map.get(params, Atom.to_string(key), default))
end
