# Changelog

All notable changes to Jidoka will be documented in this file.

This project follows conventional commits. Beta releases are intended for early
adopters while the public API is still allowed to change before a stable 1.0.

## 1.0.0-beta.1 - 2026-05-24

### Added

- Spark-backed `Jidoka.Agent` DSL for chat-oriented Elixir agents.
- Session addressing, runtime context, direct chat, streaming chat, schedules,
  AgentView projections, and Phoenix-friendly runtime guidance.
- Deterministic actions, workflows, subagents, handoffs, web/MCP capabilities,
  plugins, skills, and imported JSON/YAML agent specs with explicit registries.
- Typed results with Zoi schemas, validation, repair attempts, and
  imported-agent JSON/YAML support.
- Controls for input, operation, and result policy, including
  human-in-the-loop approval interrupts and credential-reference metadata.
- Memory, summary compaction, bounded run tracing, request inspection, and
  Kino/Livebook helpers for development-time debugging.
- Provider-free examples, smoke tests, testing guidance, a beginner Livebook,
  and an advanced kitchen-sink Livebook.

### Changed

- Refactored agent compilation, subagent runtime, imported-agent handling, and
  runtime support into smaller single-purpose modules.
- Prepared Hex package metadata and documentation for the first public beta.

### Notes

- Jidoka remains beta software. Pin exact versions for production experiments
  and expect small breaking changes before stable 1.0.
