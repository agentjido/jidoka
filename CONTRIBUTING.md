# Contributing To Jidoka

Jidoka follows the Jido ecosystem package quality standards:

- keep library code in `lib/`;
- keep example-only app wiring in `showcase/`;
- keep public documentation and standalone Livebooks in `guides/`;
- keep complete reference agents in `examples/`;
- keep local planning and research notes in the ignored `docs/` directory;
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
mix docs.check
mix test --cover
mix hex.build --unpack
```

Live provider tests are opt-in and require provider keys in the process
environment. Jidoka does not implement dotenv loading. ReqLLM loads `.env` by
default, but this source checkout disables that behavior for deterministic
tests. Use your shell or host app config to provide credentials:

```bash
mix test --include live test/jidoka/live_req_llm_test.exs
```

## Release Notes

Use conventional commits for changes. The release workflow generates release
notes from Git history. Do not edit `CHANGELOG.md` by hand. Publish through the
version-controlled GitHub release workflow, not through an ad hoc local Hex
publish.

## Jidoka-Specific Exceptions

Jidoka intentionally keeps the public package root as `Jidoka`, not
`Jido.Jidoka`, because this package is an application layer built on the Jido
ecosystem rather than a Jido core subpackage.

The Phoenix companion app lives in `showcase/`. This name separates UI and
system integration from package-level examples in `examples/`. Showcase-only
dependencies stay isolated and do not enter the primary package runtime graph.
