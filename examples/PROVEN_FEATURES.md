# Proven Feature Surface

This file records the local proof baseline from 2026-07-30. It separates
executed behavior from compile checks and live-provider work.

## Proof Levels

- **Executed**: A deterministic test or Livebook code path ran and checked the
  result.
- **Compiled**: The code and its application wiring compiled. This does not
  prove live behavior.
- **Live**: The path needs a provider key or an external service. It is not part
  of the deterministic baseline.

## Support Agent

`examples/support_agent/` is the first canonical agent scenario. One agent
definition supplies all four user surfaces:

| Surface | Entry Point | Proof |
| --- | --- | --- |
| Command | `mix jidoka.example support_agent` | Executed |
| ExUnit | `examples/support_agent/support_agent_test.exs` | Executed |
| Livebook | `examples/support_agent/support_agent.livemd` | Executed |
| Phoenix | `/agents/support` in `showcase/` | Compiled with the shared agent |

The deterministic command, test, and Livebook prove this through line:

1. The Mock LLM requests `lookup_order`.
2. The operation control checks the request.
3. The action returns order data.
4. The next model prompt contains the tool result.
5. The Mock LLM uses that result in the final answer.
6. The journal contains two model results and one operation result.
7. Authenticated access hibernates before the action runs.
8. The pending review contains the operation name and arguments.
9. Approval resumes the snapshot and runs the action once.

No recorded response, provider key, or network request is part of this proof.

## Livebook Guides

The deterministic checker ran all Elixir cells in these files:

| Livebook | Executed Feature Surface |
| --- | --- |
| `examples/guides/contracts_and_runtime.livemd` | Agent spec, inspection, preflight, tool loop, hibernate, resume |
| `examples/guides/controls_sessions_and_human_review.livemd` | Operation control, session snapshot, pending review, approval, resume |
| `examples/guides/import_eval_and_trace.livemd` | YAML import, explicit registry, trace, deterministic eval |
| `examples/guides/workflows.livemd` | Workflow definition, inspection, direct run, workflow tool, tool loop |
| `examples/support_agent/support_agent.livemd` | The complete shared Support Agent path |

Run the same check with:

```bash
for notebook in examples/guides/*.livemd examples/support_agent/*.livemd; do
  elixir scripts/check_livebook.exs "$notebook"
done
```

This check runs code cells in order in a new Elixir process. It does not test
Livebook UI controls. `mix docs` also proves that ExDoc can build these files as
documentation.

`livebook/05_approval_agent_walkthrough.livemd` is still a live-provider guide.
It needs an OpenAI key, so it is not part of the deterministic baseline. It can
move to a dedicated scenario in later work.

## Showcase Agents

The showcase baseline has 51 passing tests. Its strict application compile also
passes.

| Agent | Current Proof |
| --- | --- |
| Support | Shared scenario behavior is executed; Phoenix wiring is compiled |
| Research | Agent, browser source, controls, and route are compiled; live search is not executed |
| Approval | Review, approval, denial, and one-time action behavior are executed in Kitchen Sink |
| Ash | Resource action behavior and process visibility are executed |
| Lead Quality | Enrichment and scoring actions are executed in Kitchen Sink |
| Memory | Session recall and session isolation are executed in Kitchen Sink |
| Knowledge | Skill, MCP, browser operation sources, local lookup, and evidence control are executed |
| Debug | Inspect and preflight behavior are executed |
| Lua Tools | Catalog, sandbox, limits, repair errors, DAG, gate, reduce, parallel roots, and retry are executed |
| Kitchen Sink | Full deterministic composition, Jido process hosting, controls, review, memory, failures, and AgentView are executed |

The tests do not prove live LLM quality, browser search quality, release
deployment, or external MCP service behavior.

## Package And Dependency Gates

These checks pass at this baseline:

```bash
# Package
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix docs
mix deps.unlock --check-unused
mix hex.audit

# Showcase
cd showcase
mix format
mix compile --warnings-as-errors
mix test
mix deps.unlock --check-unused
mix hex.audit
```

The package test suite has 414 passing tests and 8 excluded live or parity
tests. The root production build contains no `JidokaExamples` modules. The
showcase production build contains the shared Support Agent `lib/` modules, but
it does not contain the scenario runner or Mock LLM.
