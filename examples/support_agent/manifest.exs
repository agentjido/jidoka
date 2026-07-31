%{
  version: 2,
  name: :support_agent,
  title: "Support Agent",
  summary: "A deterministic agent that proves a controlled tool-call lifecycle.",
  module: JidokaExamples.SupportAgent.Example,
  agent: JidokaExamples.SupportAgent.Agent,
  scenarios: [
    %{
      id: :controlled_tool_call,
      title: "Controlled Tool Call",
      intent: "A model tool request passes through control, execution, observation, and optional review.",
      execution: :deterministic,
      cases: [
        %{
          id: :allowed_round_trip,
          proves: [:tool_calling, :operation_control, :tool_observation],
          uses: [:agent, :action]
        },
        %{
          id: :interrupted_and_approved,
          proves: [:operation_control, :human_review, :snapshot_resume],
          uses: [:agent, :action, :tool_calling, :tool_observation]
        },
        %{
          id: :not_found_result,
          proves: [:tool_observation],
          uses: [:agent, :action, :tool_calling]
        }
      ]
    }
  ],
  surfaces: %{
    livebook: true,
    showcase: %{
      route: "/agents/support",
      live_view: JidokaShowcaseWeb.SupportAgentLive.Index,
      view: JidokaShowcaseWeb.SupportAgentLive.View,
      tests: ["showcase/test/support_agent_live_test.exs"],
      sources: [
        "examples/support_agent/lib/actions/lookup_order.ex",
        "examples/support_agent/lib/agent.ex",
        "examples/support_agent/lib/controls/require_order_approval.ex",
        "showcase/lib/jidoka_showcase_web/live/support_agent_live/index.ex",
        "showcase/lib/jidoka_showcase_web/live/support_agent_live/view.ex"
      ]
    }
  }
}
