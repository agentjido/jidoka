# Use Case 06: Bounded Structured-Result Repair

## Comparison contract

An agent declares an application-facing result schema. The runtime validates a
model's final value, returns the typed value when valid, supplies readable
validation feedback for a retry when invalid, and stops after an explicit
repair bound instead of accepting invalid data or looping indefinitely.

This comparison distinguishes schema validation from repair. A framework can
produce structured output without documenting an automatic validation-driven
retry, and an overall agent-loop limit is not the same as a dedicated result
repair bound.

Atomic features: `A07` typed structured final results and `A08` bounded
validation-feedback repair.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented structured-result mechanism | Repair boundary | Important boundary |
| --- | --- | --- | --- |
| Mastra | Structured output validates Standard Schema or JSON Schema into `response.object`, with strict, warn, and fallback strategies. | A separately bounded automatic validation-repair loop was not established in the reviewed docs. | Fallback behavior is not evidence that schema errors are fed back to the model for a bounded repair. |
| LangGraph / LangChain | ProviderStrategy or ToolStrategy validates Pydantic, dataclass, TypedDict, or JSON Schema output into `structured_response`. | `ToolStrategy.handle_errors` can feed validation errors back; the enclosing agent/graph step or recursion limit bounds execution. | The reviewed docs do not establish a dedicated structured-output repair count. |
| Pydantic AI | Output types and validators use Pydantic validation; validators can raise `ModelRetry`. | `output_retries` is an explicit output-retry bound, with per-output-tool overrides. | Exhaustion raises `UnexpectedModelBehavior`; validation repair is distinct from ordinary tool retries. |
| OpenAI Agents SDK | `output_type` creates a JSON Schema/Pydantic output contract; `invalid_final_output` can synthesize a validated fallback. | The fallback explicitly does not retry the model or replay tool side effects; an automatic bounded validation-repair loop was not established. | Output guardrails or fallback handling do not imply model-mediated schema repair. |
| Google ADK | `LlmAgent.output_schema` requires structured JSON and `output_key` can place the final value in session state. | An automatic bounded validation-repair loop was not established in the reviewed docs. | Combining tools and output schema is model-dependent. |
| LlamaIndex / LlamaAgents | Agents use Pydantic `output_cls`, support multi-agent and streaming structured output, and may apply a custom `structured_output_fn`. | A custom validation/rewrite hook is documented, but a dedicated bounded model-feedback repair budget was not established. | Parsed or rewritten output alone does not demonstrate retry feedback or an exact repair count. |
| AutoGen | `output_content_type` validates Pydantic output into `StructuredMessage`. | Reflection may request another response, but it is not documented as schema-validation repair; `max_tool_iterations` bounds tool looping. | Tool iteration and reflective response generation are different from a dedicated result-repair contract. |
| Jidoka | Agent DSL `result schema: ..., max_repairs: ...` validates final result data into `Turn.Result.value`. Invalid data appends a marked repair message and emits result-phase events. | Exactly `1 + max_repairs` model attempts are allowed before a typed result-phase execution error. | Repair uses the same provider-neutral model capability and applies to the final application result, not arbitrary tool outputs. |

## Executable Jidoka proof

Parity tests are opt-in and must be run from the repository root.

Run only this comparison:

```bash
mix test --only parity:bounded_structured_result_repair test/parity --trace
```

Run every parity comparison:

```bash
mix test --only parity test/parity --trace
```

The normal suite excludes parity comparisons:

```bash
mix test
```

The tagged test defines a real Jidoka DSL agent with a Zoi result schema and
`max_repairs: 1`. Deterministic LLM capabilities provide valid, repairable, and
permanently invalid sequences. A passing run proves:

- a valid first response performs one model call, emits one
  `:result_validated` event, emits no repair event, and returns a typed
  `Turn.Result.value`;
- an invalid value is never returned as success before validation;
- invalid-then-valid output performs exactly two calls under a one-repair
  budget;
- the second model prompt contains a public message marked
  `jidoka_result_repair` with repair count `1` and readable validation feedback;
- repaired success emits exactly one `:result_repair_requested` before exactly
  one `:result_validated` event and returns the corrected typed value;
- always-invalid output performs exactly `1 + max_repairs` calls and returns a
  typed `Jidoka.Error.ExecutionError` with result phase, repair attempts, and
  configured maximum; and
- the exhausted stream ends in `:turn_failed` without a validation event.

## What this does not claim

- Jidoka does not claim provider-native constrained decoding or guaranteed JSON
  generation at the token level.
- The repair pass uses the configured model capability; it does not imply a
  separate repair model or a different provider.
- This contract validates the final application result, not every operation or
  tool output.
- An exhausted run returns an error rather than a `Turn.Result` containing the
  accumulated events; callers can observe failure events through streaming.
- A dedicated result-repair count should not be equated with an overall agent
  turn limit, graph recursion limit, or tool-iteration budget in another
  framework.

## Official sources

- [Mastra structured output](https://mastra.ai/docs/agents/structured-output)
- [LangChain structured output](https://docs.langchain.com/oss/python/langchain/structured-output)
- [LangGraph Graph API](https://docs.langchain.com/oss/python/langgraph/graph-api)
- [Pydantic AI output](https://pydantic.dev/docs/ai/core-concepts/output/)
- [Pydantic AI agent API](https://pydantic.dev/docs/ai/api/pydantic-ai/agent)
- [OpenAI Agents SDK agent output](https://openai.github.io/openai-agents-python/ref/agent_output/)
- [OpenAI Agents SDK running agents](https://openai.github.io/openai-agents-python/running_agents/)
- [Google ADK LLM agents](https://adk.dev/agents/llm-agents/)
- [LlamaIndex structured output](https://developers.llamaindex.ai/python/framework/understanding/agent/structured_output/)
- [AutoGen agents](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/agents.html)
