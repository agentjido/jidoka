# AGENTS.md - Jidoka Example App

## Intent

This folder contains a Phoenix showcase app for runnable, use-case-driven
Jidoka examples.

Each example should feel like a small application a new developer can inspect,
run, and adapt. Prefer clarity over completeness.

## Example Layout

Keep one Phoenix project in `example/`:

- `mix.exs`
- `config/`
- `lib/jidoka_example/` for plain agent modules and actions
- `lib/jidoka_example_web/` for Phoenix endpoint, router, layouts, and LiveViews
- `priv/` for sample data, prompts, or fixtures

Use a path dependency back to the package root:

```elixir
{:jidoka, path: ".."}
```

## Agent Layout

Each agent example should have:

- a plain Jidoka DSL agent module;
- one or more `Jidoka.Action` modules;
- an `AgentView` module under `lib/jidoka_example_web/agent_views/` using
  `Jidoka.AgentView`;
- one LiveView under `JidokaExampleWeb.AgentLive.*`.

Phoenix should not own the agent logic. The LiveView should call the view
contract and render the projection.

## Runtime Configuration

The app should use `dotenvy` and load environment from these locations, in this
order:

1. `jidoka/.env`
2. `jidoka/example/.env`
3. the host process environment

The host process environment should win over file values.

Never commit real `.env` files. Commit `.env.example` files only.

## Runner Contract

The example app should support:

```bash
mix deps.get
mix phx.server
```

Optional CLI scripts are fine, but the web route should be the primary path.

## UI Guidance

Use one LiveView per agent. Shared UI belongs in layouts or components only when
there is real repetition.

Keep the UI quiet and task-focused:

- left navigation for examples;
- a prompt panel;
- conversation output;
- model/status fields;
- an activity panel for tool calls and raw projections.

## DSL Guidance

Examples should use the public `Jidoka.Agent` DSL and regular `Jidoka.Action`
tools. Avoid lower-level runtime modules unless the example is specifically
about harness internals.
