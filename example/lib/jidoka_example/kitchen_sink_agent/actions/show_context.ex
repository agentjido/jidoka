defmodule JidokaExample.KitchenSinkAgent.Actions.ShowContext do
  @moduledoc false

  use Jidoka.Action,
    name: "show_context",
    description: "Returns the public runtime context keys visible to a Jidoka action.",
    schema: Zoi.object(%{})

  @impl true
  def run(_params, context) do
    public_context = Jidoka.Context.data(context)

    {:ok,
     %{
       "keys" => public_context |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
       "tenant" => get(public_context, :tenant),
       "channel" => get(public_context, :channel),
       "actor" => get(public_context, :actor),
       "example" => get(public_context, :example),
       "session_id" => get(public_context, :session_id),
       "surface" => get(public_context, :surface)
     }}
  end

  defp get(context, key), do: Map.get(context, key, Map.get(context, Atom.to_string(key)))
end
