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

The app reads live LLM keys from:

1. `../.env` in the Jidoka package root
2. `example/.env`
3. the host process environment

The process environment wins.

## Current Examples

- `/agents/support` - support agent with one order lookup action.

