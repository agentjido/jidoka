# Jidoka Showcase

This is a Phoenix showcase app for runnable Jidoka examples.

## Run

```bash
cd showcase
cp .env.example .env
mix deps.get
mix jido_browser.install agent_browser --if-missing
mix phx.server
```

Open `http://localhost:4000`.

The app runs its own `JidokaShowcase.Jido` runtime and supervises example agents
as `Jido.AgentServer` children under the Phoenix application.

The Support Agent code comes from `../examples/support_agent/lib/`. Its command,
test, Livebook, and Phoenix route use one agent definition.

The app reads live LLM keys from:

1. `../.env` in the Jidoka package root
2. `showcase/.env`
3. the host process environment

The process environment wins.

The research example uses `jido_browser`. Installing the local `agent_browser`
binary keeps the example insulated from any globally installed `agent-browser`
version. Set `JIDO_BROWSER_AGENT_BROWSER_BINARY_PATH` only if you need to point
at a custom binary.

Run the complete example proof from the package root:

```bash
mix jidoka.examples.check
```

This command checks the example tests, Livebooks, command runners, and Showcase
surfaces together.

## Current Examples

- `/agents/support` - shared support agent with order lookup, operation control,
  and review support.
- `/agents/research` - research agent with browser search, page reads, structured sourced briefs, and output controls.
- `/agents/approval` - approval flow agent that hibernates before a sensitive refund action and resumes after review.
- `/agents/ash` - Ash resource-backed agent using AshJido generated Jido actions.
- `/agents/lead-quality` - multi-tool lead enrichment and scoring with structured output.
- `/agents/memory` - session memory backed by `jido_memory`.
- `/agents/knowledge` - skills plus MCP tools with optional browser-backed evidence.
- `/agents/debug` - `Jidoka.inspect/1` and `Jidoka.preflight/3` over the example agents.
- `/agents/lua-tools` - dynamic Lua scripting over a constrained hidden host tool surface.
- `/agents/kitchen-sink` - all stable features composed in one inspectable agent, including agent context and controls-as-hooks.

See `AGENT_LADDER.md` for the V1 parity map and the examples that should come
back as Jidoka grows the missing features.
