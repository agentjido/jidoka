defmodule JidokaExampleWeb.SourceExamples do
  @moduledoc false

  @root Path.expand("../..", __DIR__)

  @sources [
    %{
      id: "agent",
      label: "Agent",
      path: "lib/jidoka_example/support_agent/agent.ex"
    },
    %{
      id: "action",
      label: "Action",
      path: "lib/jidoka_example/support_agent/actions/lookup_order.ex"
    },
    %{
      id: "agent_view",
      label: "AgentView",
      path: "lib/jidoka_example_web/agent_views/support.ex"
    },
    %{
      id: "live_view",
      label: "LiveView",
      path: "lib/jidoka_example_web/live/agent_live/support.ex"
    }
  ]

  def support_agent_sources do
    Enum.map(@sources, fn source ->
      source
      |> Map.put(:source, read_source(source.path))
      |> Map.put(:path, source.path)
    end)
  end

  defp read_source(path) do
    @root
    |> Path.join(path)
    |> File.read!()
  end
end
