# Getting Started Agent

## Purpose

This is the smallest complete Jidoka conversation. It defines one agent,
starts one session, and sends two messages with repeated
`Jidoka.Session.chat/3` calls.

## Features

```text
agent definition
  -> prompt preflight
  -> session start
  -> first chat
  -> second chat with committed context
```

The example is deterministic. It does not need a provider key, network
request, recorded response, tool, or store.

The preflight report is also the local-inspection proof: it exposes the exact
first prompt and confirms that no model or operation ran. The chats then inject
one provider-free model function through the normal production turn path.

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

The command prints the normalized agent id, session id, turn count, and two
fixed answers. The second answer is `Your team is called Platform.`

## Next Guide

Read [Getting Started](../../guides/getting-started.md) for the package path.
When this flow is clear, continue with the
[Support Agent](../support_agent/README.md) to add a tool and an approval path.
