# Use Case 11: Evaluation, Datasets, and Deterministic Testing

**Roadmap status:** Docs ready; Jidoka datasets and online evals are partial/gaps.

## Comparison contract

Teams can define repeatable cases, inject deterministic model/tool behavior,
assert final and intermediate trajectory evidence, run datasets/experiments,
add custom or LLM-judge scorers, and optionally evaluate production traces.

Atomic features: `O05` deterministic evals, `O06` datasets/experiments, `O07`
judges/trajectory scoring, `O08` online evals, and `R07` test doubles.

## Framework comparison

Reviewed against official documentation on 2026-07-16.

| Package | Documented surface | Important boundary |
| --- | --- | --- |
| Mastra | Built-in/custom scorers, quick checks, trajectory/tool/safety metrics, gates/verdicts, multi-turn evals, dataset experiments, tool mocks, and CI execution. | Historical trace scoring and platform dataset management may use Mastra Platform. |
| LangChain / LangGraph | Graph tests can seed/interrupt state; LangSmith provides datasets, experiments, code/human/LLM evaluators, pairwise comparison, online evals, and feedback queues. | The broad evaluation platform is LangSmith, not LangGraph core. |
| Pydantic AI | `TestModel`, `FunctionModel`, overrides, and Pydantic Evals provide cases, datasets, lifecycle hooks, custom/LLM/span scorers, repeated runs, reports, and online evaluation. | Evals are an official package and Logfire integration is separately hosted. |
| OpenAI Agents SDK | Custom models/app tests are possible; hosted graders and trace grading evaluate full agent traces and regressions. | No SDK-native local dataset/experiment package comparable to Pydantic Evals was established. |
| Google ADK | Eval sets, CLI, local UI, programmatic tests, trajectory/tool-use criteria, rubric/LLM judges, simulations, and custom metrics. | Some advanced judges depend on Google Cloud/Agent Platform services. |
| LlamaIndex / LlamaAgents | Response and retrieval evaluation, datasets, and observability are core strengths. | A dedicated general agent-trajectory/tool-use harness was not established in the current docs. |
| AutoGen | Replay model clients and normal application tests can support deterministic scenarios. | No current integrated AgentChat trajectory/dataset/evaluation suite was established. |
| Jidoka | Injected runtime capabilities, golden projections, ExUnit integration/parity tests, and `Jidoka.Eval.Case` assertions are provider-free. | Partial: no first-class dataset/version/experiment runner, LLM-judge catalog, repeated-run report, or online eval pipeline. |

## Jidoka proof target

Define one eval that fails when the final prose is correct but the required
operation evidence is absent. Run a small dataset with deterministic fake
models, assert content plus journal/events, and emit a stable case report. Keep
datasets, judges, and online evals labeled partial until public APIs exist.

## Official sources

- [Mastra evals](https://mastra.ai/docs/evals/overview), [dataset experiments](https://mastra.ai/docs/evals/datasets/running-experiments)
- [LangGraph testing](https://docs.langchain.com/oss/python/langgraph/test), [LangSmith evaluation](https://docs.langchain.com/langsmith/evaluation)
- [Pydantic Evals](https://pydantic.dev/docs/ai/evals/evals/), [testing](https://pydantic.dev/docs/ai/guides/testing/)
- [OpenAI trace grading](https://developers.openai.com/api/docs/guides/trace-grading)
- [Google ADK evaluation](https://adk.dev/evaluate/)
- [LlamaIndex evaluation](https://developers.llamaindex.ai/python/framework/understanding/evaluating/evaluating/)
- [AutoGen replay model client](https://microsoft.github.io/autogen/stable/reference/python/autogen_ext.models.replay.html)
- [Jidoka testing and evals](../../guides/testing-and-evals.md), [contributor testing](../../guides/contributor-testing.md)
