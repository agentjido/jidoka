# Contributing To Jidoka

Jidoka follows the Jido ecosystem package quality standards:

- keep library code in `lib/`;
- keep example-only app wiring in `example/`;
- validate public data with Zoi structs;
- normalize package errors through `Jidoka.Error`;
- keep the Runic turn spine deterministic and runtime effects explicit.

## Setup

```bash
mix setup
```

Install git hooks explicitly from the primary checkout when you want local hook
coverage:

```bash
mix install_hooks
```

Hooks are not auto-installed during compile or dependency fetches.

## Quality Gate

Run the package gate before opening a PR:

```bash
mix quality
mix test --cover
mix hex.build --unpack
```

Live provider tests are opt-in and require keys in `.env` or the process
environment:

```bash
mix test --include live test/jidoka/live_req_llm_test.exs
```

## Release Notes

Use conventional commits for changes. Keep `CHANGELOG.md` current for release
preparation, and publish through the version-controlled GitHub release workflow
rather than an ad hoc local Hex publish.

## Jidoka-Specific Exceptions

Jidoka intentionally keeps the public package root as `Jidoka`, not
`Jido.Jidoka`, because this package is a named harness built on top of the Jido
ecosystem rather than a Jido core subpackage.

The Phoenix companion app currently lives in `example/` rather than
`examples/`. That singular folder name is an explicit local convention for the
single showcase app; example-only dependencies remain isolated there and do not
enter the primary package runtime graph.
