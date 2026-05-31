# Jidoka Example App

This is a Phoenix showcase app for runnable Jidoka examples.

## Run

```bash
cd example
cp .env.example .env
mix deps.get
mix phx.server
```

Open `http://localhost:4000`.

The app runs its own `JidokaExample.Jido` runtime and supervises example agents
as `Jido.AgentServer` children under the Phoenix application.

The app reads live LLM keys from:

1. `../.env` in the Jidoka package root
2. `example/.env`
3. the host process environment

The process environment wins.

Example-specific tests are optional. Use `mix format`, `mix compile`, and the
running Phoenix route as the primary validation path.

## Current Examples

- `/agents/support` - support agent with one order lookup action.
- `/agents/research` - research agent with browser search and page reads.

See `AGENT_LADDER.md` for the planned progression of examples.
