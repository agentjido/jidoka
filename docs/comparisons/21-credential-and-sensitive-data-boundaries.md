# Use Case 21: Credential and Sensitive-Data Boundaries

**Roadmap status:** Docs ready; credential brokering is a product gap.

## Comparison contract

The model may select an authenticated operation using a credential reference,
but raw secrets never enter prompts, tool arguments, transcripts, snapshots, or
traces. Trusted host code resolves/refreshes credentials at execution time, and
policy/redaction evidence remains auditable.

Atomic features: `T14` credential references/brokering, `G05` sensitive-data
trace policy, and `G06` execution permissions.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented security surface | Important boundary |
| --- | --- | --- |
| Mastra | Server auth/FGA, request context, per-request MCP credentials, sandbox permissions/approvals, and sensitive-data observability processors. | Credential injection and hosted identity/provider behavior are deployment-specific. |
| LangChain / LangGraph | Tool runtime context, middleware PII handling, LangSmith Agent Auth/MCP OAuth, secret redaction, and sandbox permissions/auth proxy. | LangSmith identity/broker services are hosted/runtime capabilities, not LangGraph core. |
| Pydantic AI | Dependency context, MCP auth/TLS, tool filtering, trace configuration, and Harness shell credential stripping/allow-deny rules. | A generic framework credential-reference/broker abstraction was not established. |
| OpenAI Agents SDK | Local context, MCP auth/approvals, sensitive trace configuration, hosted container/network policies, and sandbox permissions. | Applications still own end-user authorization and secrets passed to local tools/providers. |
| Google ADK | Tool authentication can request credentials and resume; plugins/callbacks enforce policy; managed identity/integrations provide deployment-specific security. | Credential services and provider identity are environment-specific. |
| LlamaIndex | Runtime context and normal application/tool integrations can carry auth; observability callbacks may filter data. | A first-class credential broker/reference and unified trace-redaction policy were not established. |
| AutoGen | Model/tool clients accept application credentials; Core intervention and sandbox executors can enforce local policy. | No generic credential-reference/broker or standardized secret-redaction layer was established. |
| Jidoka | `Jidoka.Context` separates public data from runtime-only capabilities; trace policy can redact/omit sensitive keys; controls can inspect operation/context metadata. | No public credential-reference type, secret-key rejection, vault/broker/proxy contract, OAuth refresh, signed outbound request, or credential-use audit projection. |

## Roadmap design target

Define a data-only credential reference and a host-side resolution capability.
Reject raw secret-looking values before prompt/tool boundaries, expose only
sanitized provider/tenant/scope/lease metadata to controls and traces, and keep
vault lookup, refresh, signing, and outbound injection outside the model and
functional core.

## Official sources

- [Mastra request context](https://mastra.ai/docs/server/request-context), [simple auth](https://mastra.ai/docs/server/auth/simple-auth.md), [fine-grained authorization](https://mastra.ai/docs/server/auth/fga.md), [observability integrations](https://mastra.ai/docs/observability/integrations/overview)
- [LangChain tool runtime](https://docs.langchain.com/oss/python/langchain/tools), [LangSmith Agent Auth](https://docs.langchain.com/langsmith/agent-auth)
- [Pydantic AI dependencies](https://pydantic.dev/docs/ai/core-concepts/dependencies/), [Harness shell](https://pydantic.dev/docs/ai/harness/shell/)
- [OpenAI Agents SDK configuration](https://openai.github.io/openai-agents-python/config/), [MCP](https://openai.github.io/openai-agents-python/mcp/)
- [Google ADK tool authentication](https://adk.dev/tools-custom/authentication/)
- [LlamaIndex agent tools](https://developers.llamaindex.ai/python/framework/module_guides/deploying/agents/tools/)
- [AutoGen intervention](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/cookbook/tool-use-with-intervention.html)
- [Jidoka context](../../guides/agent-spec-contract.md), [tracing](../../guides/tracing-and-events.md)
