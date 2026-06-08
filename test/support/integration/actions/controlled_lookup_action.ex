defmodule Jidoka.IntegrationSupport.ControlledLookupAction do
  @moduledoc false

  use Jidoka.Action,
    name: "controlled_lookup",
    description: "Looks up a controlled integration value.",
    schema:
      Zoi.object(%{
        id: Zoi.string()
      })

  @impl true
  def run(params, context) do
    id = Map.get(params, :id) || Map.get(params, "id")

    case Jidoka.Context.get(context, :test_pid) || Jidoka.Context.get_runtime(context, :test_pid) do
      nil -> :ok
      pid -> send(pid, {:controlled_lookup_called, id})
    end

    {:ok, %{id: id, value: "controlled-value", canary: "jidoka_controls_live_canary_123"}}
  end
end
