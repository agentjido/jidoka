# Proven Feature Surface

This file is the stable discovery view for the example proof system. A full,
successful `mix jidoka.examples.check` run generates the verified section.

The manifest declares expected coverage. ExUnit is the only authority that can
verify a case. Livebook, command, and showcase gates check their own surfaces.
They do not add capability coverage.

<!-- jidoka-examples-check:start -->
## Verified Capability Coverage

This table comes only from passed ExUnit proof cases in a complete check.
Livebook and showcase checks verify their surfaces. They do not add capability coverage.

| Capability | Example | Scenario | Case | Test | Livebook | Showcase |
| --- | --- | --- | --- | --- | --- | --- |
| Human Review | [Support Agent](support_agent/README.md) | Controlled Tool Call | Interrupted And Approved | [ExUnit](support_agent/test/controlled_tool_call_test.exs) | [Livebook](support_agent/support_agent.livemd) | `/agents/support` |
| Operation Control | [Support Agent](support_agent/README.md) | Controlled Tool Call | Allowed Round Trip | [ExUnit](support_agent/test/controlled_tool_call_test.exs) | [Livebook](support_agent/support_agent.livemd) | `/agents/support` |
| Operation Control | [Support Agent](support_agent/README.md) | Controlled Tool Call | Interrupted And Approved | [ExUnit](support_agent/test/controlled_tool_call_test.exs) | [Livebook](support_agent/support_agent.livemd) | `/agents/support` |
| Snapshot Resume | [Support Agent](support_agent/README.md) | Controlled Tool Call | Interrupted And Approved | [ExUnit](support_agent/test/controlled_tool_call_test.exs) | [Livebook](support_agent/support_agent.livemd) | `/agents/support` |
| Tool Calling | [Support Agent](support_agent/README.md) | Controlled Tool Call | Allowed Round Trip | [ExUnit](support_agent/test/controlled_tool_call_test.exs) | [Livebook](support_agent/support_agent.livemd) | `/agents/support` |
| Tool Observation | [Support Agent](support_agent/README.md) | Controlled Tool Call | Allowed Round Trip | [ExUnit](support_agent/test/controlled_tool_call_test.exs) | [Livebook](support_agent/support_agent.livemd) | `/agents/support` |
| Tool Observation | [Support Agent](support_agent/README.md) | Controlled Tool Call | Not Found Result | [ExUnit](support_agent/test/controlled_tool_call_test.exs) | [Livebook](support_agent/support_agent.livemd) | `/agents/support` |
<!-- jidoka-examples-check:end -->

Standalone documentation Livebooks are checked separately. They do not add
capability coverage. Showcase tests prove the UI surface, not the Jidoka
capability itself.
