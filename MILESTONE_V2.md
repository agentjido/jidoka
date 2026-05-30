# Jidoka V2 Milestone Plan

Status: complete

Date: 2026-05-30

This document records the V2 milestone work completed after the core Jidoka
kernel was proven. It is intentionally more execution-oriented than
`JIDOKA_V2.md`: each epic is small enough to drive issues, PRs, examples, and
integration tests.

## Current Checkpoint

Jidoka V2 has crossed the first important milestone:

- Spark DSL agents compile into `Jidoka.Agent.Spec`.
- JSON/YAML imports compile into the same spec contract through `Jidoka.import/2`.
- Specs, plans, effects, state, results, and snapshots are Zoi-backed data.
- The Runic turn spine can execute a ReAct-style model/tool loop.
- ReqLLM can make live LLM calls.
- Jido actions can be exposed as model-callable operations.
- `Jidoka.Harness` is the runtime boundary.
- Jido AgentServer can host a Jidoka DSL agent in a process tree.
- Input/output controls execute at runtime.
- Operation controls compile into durable spec data and execute before
  operation capabilities.
- `max_turns` and `timeout` are first-class control limits.
- Structured result schemas validate `Turn.Result.value` with bounded repair.
- Snapshots can hibernate/resume at safe boundaries.
- Splode-backed errors, trace events, inspection, preflight, golden tests,
  integration tests, and live tests are in place.

This milestone is no longer about proving the architecture. It records the
completed harness baseline for realistic agent applications while keeping
Jidoka thin, data-driven, and Jido-native.

## Sequencing Principles

- Keep `Agent.Spec` as the canonical definition boundary.
- Keep the Runic workflow as the owner of turn control flow.
- Keep external work behind `Effect.Intent` / `Effect.Result`.
- Prefer typed data contracts before runtime convenience APIs.
- Add runtime execution only after the corresponding data shape is testable.
- Preserve deterministic tests for every live/example flow.
- Avoid reintroducing V1 vocabulary drift: public policy is `controls`, work is
  `operations`, app-facing output is `result`.

## Epic 1: Operation Control Runtime

Goal: make `controls do operation ... end` enforce policy around executable
work, not just compile into spec data.

Why it matters: this is the missing bridge between the clean controls DSL and
real safety boundaries for tool/action execution. It also unlocks
human-in-the-loop approvals.

Deliverables:

- `Jidoka.Control.OperationRequest` or equivalent typed context passed to
  operation controls.
- Runtime matching for operation controls by `kind`, `name`, and later metadata.
- Before-operation control execution.
- After-operation control execution only if the contract stays simple; defer if
  it complicates the first slice.
- Deterministic ordering for multiple matching controls.
- Control events for requested/allowed/blocked/interrupted/failed decisions.
- Error normalization for operation-control failures.
- Tests for allow, block, interrupt, invalid return, raised exception, duplicate
  declarations, and non-matching controls.

Design notes:

- Start with `:before` operation controls only.
- Match current operation effects before `EffectInterpreter` calls the runtime.
- Treat the control context as immutable data.
- Do not call controls from the Jido action runtime; controls belong in the
  Jidoka runtime shell around effect interpretation.

Exit criteria:

- A risky action can be blocked before execution.
- A risky action can return an interrupt instead of executing.
- Non-matching operation controls do not run.
- Trace shows control decisions before capability calls.
- Existing input/output controls keep their current behavior.

Status:

- Implemented the before-operation runtime slice.
- Matching supports operation `kind` and `name`.
- Matching Jido actions are classified as `:action`.
- Operation controls receive typed
  `Jidoka.Runtime.Controls.OperationContext` data.
- Allow, block, interrupt, invalid decision, raised exception, duplicate
  declaration, and non-matching cases have deterministic integration coverage.
- Live controls integration verifies a real model-triggered tool call through
  the operation-control boundary.

Deferred:

- Durable interrupt/approval resume moves to Epic 2.
- After-operation controls remain deferred until result contracts and operation
  journals are more formal.
- Blocked/interrupted/failed control trace events should be revisited when
  errors can carry failed turn state or harness sessions can persist partial
  traces.

## Epic 2: Interrupts And Human-In-The-Loop

Goal: make `{:interrupt, reason}` a durable, resumable control outcome.

Why it matters: human approval is a core agent-harness capability. Returning an
interrupt is not enough; applications need a stable pending object and a resume
path.

Deliverables:

- `Jidoka.Review.Interrupt` data struct.
- `Jidoka.Review.Request` and `Jidoka.Review.Response` data structs.
- Turn status for pending review.
- Snapshot cursor for `:review` / `:wait` boundaries.
- Resume API that applies an approval/denial response and continues or fails.
- Harness-level pending review metadata.
- Tests for approve, deny, expired approval, malformed response, and resume
  after process restart via serialized snapshot.

Design notes:

- Approval storage should be a harness concern, not a core workflow concern.
- The core snapshot should contain enough semantic state to resume without the
  original process.
- Start with operation-control interrupts; expand to input/output controls after
  the shape is stable.

Exit criteria:

- A control can interrupt before an operation.
- The agent can hibernate with a pending approval.
- The caller can resume with approval and execute the operation.
- The caller can resume with denial and receive a deterministic failure.

Status:

- Implemented durable operation-control interrupts.
- `Jidoka.Review.Interrupt`, `Jidoka.Review.Request`, and
  `Jidoka.Review.Response` are Zoi-backed data contracts.
- Interrupted turns hibernate with `cursor.phase == :review`,
  `turn_state.status == :waiting`, and a `pending_review` snapshot metadata
  entry.
- `Jidoka.resume/2` accepts `approval:` / `approval_response:` and resumes the
  pending operation on approval.
- Denials, expired approvals, malformed responses, mismatched interrupts, and
  missing approval responses are deterministic.
- Serialized review snapshots can resume after approval.

Deferred:

- External approval stores and inbox queries move to Epic 5.
- Input/result interrupt durability can be added after operation review is used
  in examples.
- Review trace persistence for failed resumes should be revisited with harness
  sessions.

## Epic 3: Structured Result Contracts

Goal: make app-facing results typed, validated, and repairable.

Why it matters: agent harnesses are most useful when application code can depend
on structured outputs, not just assistant text.

Deliverables:

- `Jidoka.Agent.Spec.Result` data contract.
- Agent DSL support for structured result schema in the `agent` block.
- JSON/YAML import support for result schema refs through registries.
- Model-decision protocol support for structured final values.
- Validation/coercion through Zoi.
- Bounded repair loop for invalid model output.
- Output controls after validation and repair.
- Projection/golden-test coverage.

Design notes:

- Keep public language as `result`.
- Avoid overfitting to a provider-specific structured-output API at first.
- Store both raw model final output and validated app-facing result if useful
  for trace/debugging.
- Keep repair limits explicit and deterministic.

Exit criteria:

- A DSL agent can declare a Zoi result schema.
- A fake LLM returning valid structured data produces a typed result.
- Invalid structured data can repair up to the configured bound.
- Invalid structured data fails deterministically after repair is exhausted.
- Output controls receive the validated output boundary.

Status:

- Implemented `Jidoka.Agent.Spec.Result`.
- DSL agents can declare `result schema: ..., max_repairs: ...`.
- JSON/YAML imports can resolve result schema refs through `result_schemas`.
- Final model decisions can include structured `result` values.
- `Turn.Result.value` exposes the validated app-facing value.
- Invalid result values trigger bounded repair turns and deterministic
  result-phase failures after repair exhaustion.
- Output controls receive validated `result_value` data.
- Projection, DSL, import, and integration tests cover the first slice.

Deferred:

- Native provider structured-output configuration remains deferred; the current
  contract stays provider-neutral through the model-decision protocol.
- Rich JSON schema projection from Zoi remains deferred until docs/examples need
  more than `schema?: true`.

## Epic 4: Formal Operation Contracts And Idempotency

Goal: make operation execution durable, replayable, and policy-aware.

Why it matters: effects must be safe across hibernate/resume and crash/retry
boundaries. The current loop has deterministic keys, but operation contracts
need to become explicit enough for production use.

Deliverables:

- Formal operation request/result structs used at runtime boundaries.
- Operation idempotency policy docs and validation.
- Explicit policy support for `:pure`, `:idempotent`, `:dedupe`,
  `:reconcile`, and `:unsafe_once`.
- Runtime enforcement for unsafe policies requiring controls.
- Effect journal replay tests for operation effects.
- Reconciliation error/interrupt shape for incomplete unsafe effects.

Design notes:

- Do not rely on raw effect payload maps as the long-term public contract.
- Idempotency keys should include stable agent/session/request/operation inputs.
- Unsafe once should not be silently retried.

Exit criteria:

- Operation effects replay from journal without duplicate action execution.
- Unsafe operations require an explicit control or fail at plan/preflight time.
- Reconciliation cases are surfaced as typed errors or interrupts.

Status:

- `Jidoka.Effect.OperationRequest` and `Jidoka.Effect.OperationResult` are the
  runtime operation boundary structs.
- `Jidoka.Agent.Spec.Operation` now exposes operation kind, replay-safety, and
  explicit-control policy helpers.
- `Turn.Plan`, `Jidoka.preflight/3`, `Jidoka.run_turn/3`, and runtime operation
  planning reject `:unsafe_once` operations without a matching operation
  control.
- Operation control matching is shared between spec policy validation and
  runtime control execution.
- `Effect.Journal` can identify recorded and incomplete intents.
- Journaled operation results replay without calling the operation capability.
- Incomplete `:unsafe_once` operation intents return a typed execution error
  instead of retrying.
- Unit and integration tests cover unsafe policy validation, controlled unsafe
  execution, operation replay, and incomplete unsafe reconciliation.

Deferred:

- `:reconcile` currently remains a policy marker; a full reconciliation
  interrupt/work queue belongs with Epic 5 harness sessions and stores.
- Idempotency keys do not yet include a formal harness session id because
  sessions are introduced in Epic 5.

## Epic 5: Harness Sessions, Stores, And Replay

Goal: make the harness operable across requests and process restarts without
turning Jidoka into a full platform.

Why it matters: the kernel is process-agnostic. A production harness needs a
small store and session contract to make that practical.

Deliverables:

- `Jidoka.Harness.Session` data struct.
- `Jidoka.Harness.Store` behaviour.
- In-memory store implementation for tests/examples.
- Snapshot persistence API.
- Replay API over snapshots and journals.
- Pending approval listing/query shape.
- History/diff helpers for debugging.
- Tests for session run, hibernate, resume, replay, and approval lookup.

Design notes:

- Keep storage swappable.
- Avoid database assumptions in core.
- Store semantic state, not process state.
- Jido AgentServer hosting should be one harness deployment mode, not the only
  runtime story.

Exit criteria:

- A session can run, persist a snapshot, and resume later.
- Replay can reconstruct trace/history from stored data.
- Approval requests can be listed without knowing process internals.

Status:

- Added `Jidoka.Harness.Session` as a Zoi-backed session envelope around spec,
  requests, snapshots, result, pending reviews, error, and metadata.
- Added `Jidoka.Harness.Store` behaviour plus
  `Jidoka.Harness.Store.InMemory` for tests/examples.
- Added harness APIs for `start_session/2`, `run_session/3`,
  `resume_session/2`, pending review listing, and session/snapshot replay.
- Added `Jidoka.Harness.Replay` as a data-only projection over snapshots,
  journals, events, pending reviews, and result state.
- Stored sessions can hibernate, persist a snapshot, resume by session id, and
  write the finished result back to the store.
- Pending operation approvals can be listed from the store and resumed by
  approval response.
- Session and replay projections are available through `Jidoka.projection/1`
  and `Jidoka.inspect/1`.

Deferred:

- Store implementations beyond in-memory remain deferred until a concrete app
  chooses a persistence backend.
- Replay is a projection/history view, not a CLI or deterministic re-executor.
- Session queues, concurrency limits, and external approval inbox mechanics are
  still backlog items for later harness hardening.

## Epic 6: Memory And Compaction

Goal: make long-running agent context manageable while preserving transcript
truth.

Why it matters: real agents need continuity. Memory and compaction should be
visible data, not hidden prompt mutation.

Deliverables:

- Memory recall/write effect contracts.
- Memory store behaviour.
- Conversation memory policy in `Agent.Spec`.
- Compaction request/result structs.
- Compaction snapshots with source-message provenance.
- Prompt assembly that includes recalled memory and compacted summaries.
- Trace events for recall/write/compact decisions.
- Tests for deterministic fake memory and compaction.

Design notes:

- Memory should not be a generic hidden map.
- Compaction should preserve a link back to source messages.
- Keep memory effects behind the effect interpreter.

Exit criteria:

- A multi-turn agent can recall memory through an injected store.
- A compaction snapshot can be serialized with provenance.
- Prompt preflight shows memory/compaction contributions.

Status:

- Added `Jidoka.Agent.Spec.Memory` as optional memory policy data with agent or
  session scope.
- Added memory recall/write contracts:
  `Jidoka.Memory.Entry`, `RecallRequest`, `RecallResult`, `WriteRequest`, and
  `WriteResult`.
- Added `Jidoka.Memory.Store` behaviour plus deterministic
  `Jidoka.Memory.Store.InMemory`.
- Added `Jidoka.Memory.Compaction` as a serializable compaction snapshot with
  source-message provenance.
- Harness run/preflight recall memory through `memory_store:` and pass typed
  `RecallResult` data into turn state.
- Prompt assembly emits `memory_recalled`, adds a compact memory system
  message, and exposes `prompt.memory`.
- `Jidoka.Harness.write_memory/3` writes entries through the configured memory
  store.
- DSL and JSON/YAML imports accept simple memory policy data.
- Unit and integration tests cover memory policy normalization, write/recall,
  session-scoped memory, preflight visibility, prompt assembly, and compaction
  serialization.

Deferred:

- Memory is currently recalled by the harness before the Runic loop rather than
  planned as a first-class `Effect.Intent`; the data contracts are in place for
  a future effect-shell migration if needed.
- Runtime compaction execution is not implemented yet; the compaction snapshot
  contract is available for the next slice that needs it.

## Epic 7: Expanded Jido-Native Operation Sources

Goal: grow beyond direct Jido actions while preserving one operation model.

Why it matters: Jidoka should feel like the simple agent harness for the Jido
ecosystem, but all executable work should still normalize to operations.

Candidate surfaces:

- Jido actions beyond the current direct runtime.
- Jido agent/subagent operation calls.
- Workflow operations.
- Handoff operations.
- Ash/Jido integrations where they fit the thin harness boundary.
- MCP or external tool catalogs only after operation metadata and controls are
  stable.

Deliverables:

- Operation source behaviour or extension point.
- Operation metadata contract for kind/name/schema/risk/source.
- Prompt exposure rules for mixed operation sources.
- Control matching across operation kinds.
- Tests for name conflicts and kind-specific routing.

Design notes:

- Keep `tools do ... end` as the authoring block.
- Keep runtime execution through `Effect.Intent`.
- Avoid separate code paths for every operation source.

Exit criteria:

- At least one non-action operation source runs through the same turn loop.
- Operation controls can match it by kind/name.
- Projection/preflight shows the same operation shape.

Status:

- Added `Jidoka.Operation.Source` behaviour/delegator for compiling sources
  into `Agent.Spec.Operation` data plus one runtime capability.
- Added `Jidoka.Operation.Source.Local` as the first non-action source.
- Local source metadata records source/kind and normalizes to the existing
  operation kind/name control contract.
- Source compiler rejects duplicate operation names across mixed sources.
- Routed source capability dispatches by operation name and still returns
  through the existing `Effect.Intent` / `Effect.Result` path.
- Integration coverage proves a `:tool` source runs through the normal turn
  loop and operation controls match it by `kind` and `name`.

Deferred:

- Jido subagent/workflow/handoff/Ash/MCP sources remain future source
  implementations; the spine is now ready for them.
- The public DSL still exposes `tools do action ... end`; richer source DSL
  sugar can be added after source demand is clearer.

## Epic 8: Observability, Inspection, And Evals

Goal: make Jidoka easy to debug, inspect, and regression-test as behavior grows.

Why it matters: agent systems are hard to trust without stable introspection.
The current trace/projection work is a strong base, but needs persistence and
examples.

Deliverables:

- Optional trace sink behaviour.
- Trace sampling/redaction policy.
- Inspection views for controls, effects, replay, and approvals.
- Golden tests for DSL/import/result/control projections.
- Example-backed integration tests for common harness flows.
- Eval case data structure for deterministic fake runs and optional live runs.

Design notes:

- Keep trace payloads sanitized by default.
- Prefer projection-based golden tests over raw struct comparisons.
- Do not let inspection APIs depend on provider-specific objects.

Exit criteria:

- A failed turn can explain which control/effect/operation failed.
- A replayed turn can show what was reused from the journal.
- Examples double as integration tests.

Status:

- Implemented `Jidoka.Trace.Policy` with enablement, sampling, redaction, and
  omit-key defaults.
- Implemented `Jidoka.Trace.Sink` and `Jidoka.Trace.Sink.InMemory`.
- `Jidoka.Trace.record/3` projects events through policy before handing them to
  caller-provided sinks.
- `Jidoka.inspect/1` now has explicit views for sessions, replay, effect
  journals, effect intents/results, review requests/responses/interrupts,
  memory recall/write results, and eval runs.
- Implemented deterministic `Jidoka.Eval.Case` and `Jidoka.Eval.Run` data
  contracts.
- `Jidoka.Eval.run_case/2` executes through the existing harness and supports
  content equality, content containment, and operation-called assertions.
- Observability integration coverage ties harness session replay, inspection,
  trace sink recording, and eval evidence together.

Deferred:

- Logger, telemetry, and durable trace-store sinks remain future sink
  implementations.
- Inspection diff/time-travel helpers remain deferred until there is a richer
  state-history store.
- Live eval datasets remain optional and should build on the deterministic
  `Jidoka.Eval` contracts instead of adding a second eval runtime.

## Epic 9: Documentation, Examples, And Livebook

Goal: make the V2 package teachable from first agent through durable approvals.

Deliverables:

- Getting started guide kept current with the actual DSL.
- Controls guide covering input, operation, result, interrupts, and limits.
- Structured results guide.
- Harness/session/durability guide.
- Live LLM tool-loop guide.
- Livebook for local exploration without provider credentials where possible.
- Example agents organized under reusable support modules.

Exit criteria:

- A new user can build a one-tool agent from docs.
- A new user can add one input control and one operation approval from docs.
- A new user can run deterministic tests without live keys.
- Live examples are opt-in and documented through `.env.example`.

Status:

- Added standalone [Controls](guides/controls.md) coverage for input,
  operation, output, interrupts, and loop limits.
- Added standalone [Structured Results](guides/structured-results.md) coverage
  for Zoi result schemas, repair, output controls, and import refs.
- Refreshed README and getting-started guide links around the current guide
  set.
- Refreshed the Livebook with deterministic preflight, trace sink, eval, and
  structured-result examples.
- Added documented-example integration coverage for the one-tool loop and input
  controls.

Deferred:

- More narrative around migration from V1 belongs in Epic 10 release hardening.
- Production deployment examples should wait for durable store/runtime choices.

## Epic 10: Release Hardening

Goal: make V2 reliable enough to treat as a package, not just a spike.

Deliverables:

- Public API audit.
- Typespec and Dialyzer cleanup.
- Coverage threshold maintained at or above 80%.
- Formatting, xref, compile warnings, and Dialyzer in the normal check path.
- Changelog and migration notes from V1 vocabulary.
- Versioned snapshot/import contracts.
- Clear beta/non-beta API boundaries.

Exit criteria:

- `mix test`, `mix test --cover`, `mix format --check-formatted`,
  `mix compile --warnings-as-errors --force`, `mix xref`, and `mix dialyzer`
  pass.
- Public docs avoid stale V1 terms except in migration notes.
- Snapshot/import versions are explicit.
- The next feature can be added without reshaping the kernel.

Status:

- Removed the public `adapters:` runtime alias in favor of `capabilities:`.
- Enforced import document `version: 1` through `Jidoka.Import.AgentDocument`.
- Added [CHANGELOG.md](CHANGELOG.md) for the V2 milestone baseline.
- Added [Migration From V1](guides/migration-from-v1.md) covering vocabulary,
  API shape, and versioned contracts.
- README now documents API stability boundaries and versioned data contracts.
- Runtime guide documents snapshot, session, and import version boundaries.

Final verification:

- `mix format --check-formatted` passes.
- `mix test` passes with 200 tests.
- `mix test --cover` passes at 80.27% coverage.
- `mix compile --warnings-as-errors --force` passes.
- `mix xref graph --format cycles --label compile` reports no cycles.
- `mix dialyzer` passes with no errors.
- `mix test --include live test/jidoka/live_req_llm_test.exs` passes.

## Recommended Next Slice

After the final quality gate, the V2 milestone should be considered complete.
The next work should be chosen as a new milestone rather than added to this
plan.
