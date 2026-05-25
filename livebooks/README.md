# Jidoka Livebooks

These notebooks are the teaching track for Jidoka. Each notebook focuses on one
concept, proves it provider-free first, then offers an optional live-provider
cell when that makes the concept clearer.

## Notebooks

1. [Your First Agent](01_first_agent.livemd)

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fagentjido%2Fjidoka%2Fblob%2Fmain%2Flivebooks%2F01_first_agent.livemd)

## Template

Use [CONCEPT_TEMPLATE.md](CONCEPT_TEMPLATE.md) before adding another concept
notebook. The goal is a consistent teaching rhythm:

1. Explain the concept in one paragraph.
2. Show the smallest useful code.
3. Inspect what Jidoka generated.
4. Run a provider-free exercise.
5. Show the debugging view.
6. Add one optional live-provider cell only when useful.

## Local Dev Endpoint Testing

Livebook dev endpoints are local HTTP endpoints under `/dev`. They are disabled
by default in Livebook settings. Once enabled, open or sync a notebook with:

```bash
curl -sfS -X POST http://localhost:32123/dev/open \
  -H 'content-type: application/json' \
  -d '{"file":"/absolute/path/to/jidoka/livebooks/01_first_agent.livemd"}'

curl -sfS -X POST http://localhost:32123/dev/sync \
  -H 'content-type: application/json' \
  -d '{"file":"/absolute/path/to/jidoka/livebooks/01_first_agent.livemd"}'
```

Those endpoints open or synchronize the notebook session. They do not execute
cells, so keep every code cell independently evaluable and run a local code-fence
smoke test before shipping.
