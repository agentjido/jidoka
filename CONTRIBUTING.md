# Contributing to Jidoka

Jidoka is an experimental package built on top of Jido and Jido.AI. The current
goal is to find the smallest useful public API for common LLM agent patterns.

## Development

```bash
mix setup
mix test
mix quality
```

Use `mix install_hooks` only from the primary repository checkout if you want
local git hooks. Hook auto-install is intentionally disabled so worktrees and
automation environments remain safe.

## Quality Bar

Jidoka follows the Jido package quality standards:

- use conventional commits
- keep examples outside shipped library internals
- keep public modules documented or explicitly internal
- run formatting, compile warnings, tests, linting, and docs through `mix quality`
- prefer Zoi for validation and Splode for package error types

## Pull Requests

- Keep changes focused and explain public API changes clearly.
- Add or update tests with behavior changes.
- Update `README.md` or `CHANGELOG.md` when a change affects package direction
  or user-facing workflows.
- Do not commit secrets, `.env`, generated docs, or coverage reports.

## Release Status

Jidoka is not released. Any API may change before the first Hex package.
