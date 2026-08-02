# Governed Tools Agent

## Purpose

The Governed Tools Agent groups the package capabilities for controlled tool
composition and local quality checks. It adds only one example application to
cover skills, progressive catalog discovery, read-only browser tools, and
deterministic eval evidence.

## Features

The example proves the shipped boundaries:

- one Zoi action schema becomes one model-visible operation schema;
- one skill contributes prompt text and a fixed action set;
- one hidden catalog is exposed through query, describe, and bounded
  execute operations;
- read-only browser tools enforce an allowlisted public URL;
- `Jidoka.Eval` runs the normal agent path with provider-free capabilities;
- ordinary Elixir can group repeatable eval cases and calculate a trajectory
  score from public observations;
- Kino renders preflight and graph evidence in development and test builds.

The example does not claim a general per-request tool-preparation hook, a
first-class dataset or scorer protocol, interactive browser automation, or a
packaged Studio. Those remain explicit partial boundaries.

## Read It In This Order

1. `lib/agent.ex` - one agent with skill, catalog, and browser sources.
2. `lib/skill.ex` - reusable instructions and one bounded action.
3. `lib/catalog.ex` - the hidden read-only action catalog.
4. `lib/scenario.ex` - deterministic tool and eval execution.
5. `test/governed_tools_test.exs` - exact shipped guarantees and partial
   boundaries.
6. `governed_tools.livemd` - the local inspection and quality walkthrough.

The agent, action, skill, and catalog are application patterns. Browser
doubles, scripted model functions, eval grouping, and tests are deterministic
example support.

## Run It

```bash
mix run examples/governed_tools/example.exs
mix test --only example:governed_tools
mix test examples/governed_tools/test/governed_tools_test.exs --trace
mix run scripts/check_livebooks.exs -- --project examples/governed_tools/governed_tools.livemd
```

No command uses a provider key or network request.

## Expected Result

The command prints seven stable model-visible operations, one skill result,
one catalog result, one allowlisted browser result, and two eval statuses. The
second eval has correct prose but fails because it did not call the required
policy operation.

## Next Guide

Read [Skill, Workflow, And Subagent Tools](../../guides/skill-workflow-subagent-tools.md),
[Browser Tools](../../guides/browser-tools.md), and
[Testing And Evals](../../guides/testing-and-evals.md).
