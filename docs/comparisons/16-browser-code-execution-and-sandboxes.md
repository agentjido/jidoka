# Use Case 16: Browser, Code Execution, and Sandboxes

**Roadmap status:** Docs ready; Jidoka has narrow read-only web tools and no sandbox.

## Comparison contract

An agent can retrieve web content, optionally control an interactive browser,
run code/shell/patch operations inside a permissioned workspace, stream
artifacts, and require review for risky actions without escaping its sandbox.

Atomic features: `T11` web/browser tools, `T12` code/shell/computer use, and
`G06` sandbox/permissions.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented execution environment | Important boundary |
| --- | --- | --- |
| Mastra | Read/search plus Playwright/Stagehand browser automation, recordings/viewer, workspace filesystem/search/LSP, code mode, local/cloud sandboxes, background processes, and approvals. | Browser and sandbox providers have different network, credential, persistence, and isolation guarantees. |
| LangChain / Deep Agents | Browser integrations, headless frontend tools, provider code interpreters, virtual filesystems, multiple sandbox backends, shell `execute`, and scoped QuickJS. | Most browser/sandbox implementations are integrations or LangSmith services, not LangChain core. |
| Pydantic AI | Provider-native search/fetch/code tools plus Harness filesystem, shell, background processes, credential stripping, and sandboxed code mode. | No first-party GUI/browser automation harness was established; web fetch is not browser control. |
| OpenAI Agents SDK | Hosted web search/code interpreter/tool search/shell, local shell/patch adapters, `ComputerTool`, and beta sandbox agents with workspace snapshots and permissions. | Hosted and local execution have different trust and data boundaries. |
| Google ADK | Built-in/provider code execution, managed executors, Google Search, and Gemini Computer Use integrations. | Computer Use is provider-specific, not a model-neutral browser runtime. |
| LlamaIndex | `CodeActAgent` and tool integrations can perform web/code work. | Safe executor/browser lifecycle is application or integration owned; no first-class browser sandbox was established. |
| AutoGen | WebSurfer/FileSurfer/VideoSurfer, CodeExecutorAgent, local/Docker/Jupyter/Azure executors, and code-execution tools. | Agent and executor are separate components; parallel stateful tools need coordination. |
| Jidoka | Built-in browser operations intentionally support bounded search/read/snapshot behavior with URL allowlists, private-host blocking, clamps, and deterministic fake capabilities. | No click/type/JS/browser session, filesystem, shell, patch, computer use, artifacts, workspace, or sandbox contract. |

## Roadmap decision

The next proof should demonstrate only Jidoka's narrow read-only web safety
contract. Interactive browser/code/shell work should be designed as a companion
operation source or Jido runtime capability with explicit filesystem, network,
credential, approval, timeout, and artifact policies.

## Official sources

- [Mastra browser](https://mastra.ai/docs/browser/overview), [sandbox](https://mastra.ai/docs/workspace/sandbox)
- [Deep Agents sandboxes](https://docs.langchain.com/oss/python/deepagents/sandboxes), [interpreters](https://docs.langchain.com/oss/python/deepagents/interpreters)
- [Pydantic Harness filesystem](https://pydantic.dev/docs/ai/harness/filesystem/), [shell](https://pydantic.dev/docs/ai/harness/shell/), [code mode](https://pydantic.dev/docs/ai/harness/code-mode/)
- [OpenAI Agents SDK tools](https://openai.github.io/openai-agents-python/tools/), [sandbox guide](https://openai.github.io/openai-agents-python/sandbox/guide/)
- [Google ADK integrations](https://adk.dev/integrations/)
- [LlamaIndex agents](https://developers.llamaindex.ai/python/framework/module_guides/deploying/agents/)
- [AutoGen WebSurfer](https://microsoft.github.io/autogen/stable/reference/python/autogen_ext.agents.web_surfer.html), [code executors](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/components/command-line-code-executors.html)
- [Jidoka browser tools](../../guides/browser-tools.md)
