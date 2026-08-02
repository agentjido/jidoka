# Getting Started Agent

## Purpose

This is the smallest complete Jidoka example. It defines one agent, sends one
text request, and returns one final answer.

## Features

```text
agent definition
  -> prompt preflight
  -> one model call
  -> final text answer
```

The example is deterministic. It does not need a provider key, network
request, recorded response, tool, session, or store.

The preflight report is also the local-inspection proof: it exposes the exact
prompt and confirms that no model or operation ran. The chat then injects one
provider-free model function through the normal production turn path.

## Read It In This Order

1. `lib/agent.ex` - the application code to copy.
2. `lib/scenario.ex` - deterministic local execution for this example.
3. `test/getting_started_test.exs` - the application behavior check.
4. `example.exs` - the guided command runner.
5. `getting_started.livemd` - the interactive walkthrough.

The agent module is the production pattern. The scenario, injected model
function, runner, manifest, and test are example support. In production, the
agent uses its declared model and the provider credentials from the runtime
environment.

## Run It

```bash
mix run examples/getting_started/example.exs
mix test --only example:getting_started
mix test examples/getting_started/test/getting_started_test.exs --trace
```

Open `getting_started.livemd` to inspect the compiled agent, preview its exact
prompt, and run the same deterministic chat.

## Expected Result

The command prints the normalized agent id, prompt messages, and this fixed
answer: `I can explain Jidoka agents and help you build one.`

## Next Guide

Read [Getting Started](../../guides/getting-started.md) for the package path.
When this flow is clear, continue with the
[Support Agent](../support_agent/README.md) to add a tool and an approval path.
