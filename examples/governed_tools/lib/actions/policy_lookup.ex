defmodule JidokaExamples.GovernedTools.Actions.PolicyLookup do
  @moduledoc false

  alias Jidoka.Schema

  use Jidoka.Action,
    name: "research_policy_lookup",
    description: "Returns the approved research policy for one topic.",
    category: "research",
    tags: ["research", "policy", "read_only"],
    schema:
      Zoi.object(%{
        topic: Zoi.string()
      })

  @impl true
  def run(params, context) do
    topic = Schema.get_key(params, :topic) |> to_string() |> String.trim()
    notify(context, {:research_policy_called, topic})

    {:ok,
     %{
       "citation_required" => true,
       "policy" => "Use approved public sources and cite the source URL.",
       "topic" => topic
     }}
  end

  defp notify(context, message) do
    case Jidoka.Context.get_runtime(context, :example_observer) do
      observer when is_pid(observer) -> send(observer, message)
      _observer -> :ok
    end
  end
end
