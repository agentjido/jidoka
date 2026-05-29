# Live LLM Tool Loop

Live tests are opt-in so normal unit tests remain deterministic.

## Configure Keys

```bash
cp .env.example .env
```

Then add at least one key:

```bash
OPENAI_API_KEY=...
ANTHROPIC_API_KEY=...
```

Optionally choose a model:

```bash
JIDOKA_DEFAULT_MODEL=openai:gpt-4o-mini
```

## Run The Live Test

```bash
mix test --include live test/jidoka/live_req_llm_test.exs
```

The live test proves:

- the Spark DSL compiles to a Jido-backed agent module;
- ReqLLM makes a real model call;
- the model chooses one operation;
- the operation runs through Jido.Action.Tool;
- the model receives the observation and produces the final answer.

## Current Protocol

The current ReqLLM runtime uses a constrained JSON decision protocol:

```json
{"type":"final","content":"answer"}
```

or:

```json
{"type":"operation","name":"local_time","arguments":{"city":"Chicago"}}
```

This keeps the Runic/effect spine provider-neutral while the V2 runtime
settles. Native provider tool-calling can replace this protocol later without
changing `Agent.Spec` or the harness boundary.
