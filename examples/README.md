# Jidoka Examples

The examples are runnable agent scenarios. They are designed for two uses:

- teaching new users what they can build with Jidoka
- live integration checks that make real model calls when provider credentials
  are configured

Provider-free verification is the default:

```bash
mix jidoka.example --list
mix jidoka.example support_agent
mix jidoka.example --all
```

Live runs use the same example modules but call `Jidoka.chat/3`:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
mix jidoka.example support_agent --live
mix jidoka.example --all --live
```

You can override the user prompt:

```bash
mix jidoka.example ticket_classifier --live --prompt "Classify this renewal invoice complaint."
```

## Examples

| Name | What It Covers |
| --- | --- |
| `first_agent` | minimal agent, model alias, instructions, session, prompt preflight |
| `ticket_classifier` | context schema, structured result, validation repair |
| `support_agent` | actions, operation controls, human approval, credential references |
| `debug_agent` | provider-free interrupt, request inspection, trace inspection |
| `workflow_agent` | workflow DSL, generated workflow tool, manual schedule run |
| `delegation_agent` | subagent call, handoff ownership, imported agent spec |
| `knowledge_agent` | skills, plugin tools, MCP tools, web tools |
| `ash_agent` | Ash resource expansion, generated AshJido tools, actor/domain context |

## File Layout

`registry.exs` defines the example registry and shared runner helpers. Each
example lives in its own folder with source split by role:

```text
examples/support_agent/
  actions/
  controls/
  agents/
  example.exs
```

`example.exs` contains the small `run/1` module used by the mix task. Supporting
actions, controls, agents, workflows, skills, plugins, resources, and other
domain modules stay in named subfolders so each example can grow into a useful
reference without turning the root `examples/` directory into a flat script
dump.

Example agents use `tools do ... end` for actions and integrations that become
model-callable operations. The legacy `capabilities` block has been removed
from the Elixir agent DSL.

## Live Integration Policy

Default example runs must stay deterministic and provider-free. Live mode should
exercise the same agent with a short prompt and accept normal Jidoka outcomes:
`{:ok, result}`, `{:interrupt, interrupt}`, or `{:handoff, handoff}`. Chat
errors fail the example so `mix jidoka.example --all --live` can catch runtime
regressions. A live run requires `ANTHROPIC_API_KEY` or an explicitly provided
`--provider-env` value.
