%{
  name: :support_agent,
  title: "Support Agent",
  module: JidokaExamples.SupportAgent.Example,
  files: [
    "lib/actions/lookup_order.ex",
    "lib/controls/require_order_approval.ex",
    "lib/agent.ex",
    "support/mock_llm.ex",
    "example.exs"
  ],
  test: "support_agent_test.exs",
  livebook: "support_agent.livemd",
  features: [
    :agent,
    :action,
    :tool_calling,
    :tool_observation,
    :operation_control,
    :human_review,
    :snapshot_resume
  ]
}
