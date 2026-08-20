# Jidoka simplification audit tasks

This folder contains the accepted tasks from the full codebase simplification audit completed on 2026-08-16 and signed off on 2026-08-20.

- Status: `done`
- Accepted tasks: 41
- Completed tasks: 41
- Open tasks: 0
- Covered subsystems: 61
- Subsystems with accepted tasks: 32
- Explicitly skipped subsystems: 29
- Tests run during the original read-only audit: none

The original audit was read-only. The task files retain the accepted evidence, scope, and acceptance criteria. Their `done` status records the completed implementation and validation described below.

## Completion sign-off

All 41 accepted tasks are complete.

- Implementation: merged commit `29246d0a` (`fix: address code audit findings (#60)`).
- Source evidence: the final `fix/audit-findings` tree and the merged commit tree are identical.
- Task evidence: every accepted task ID has a matching implementation commit, and each task commit changes at least one test or validation script.
- Regression evidence: no audit tests were deleted after the merge.
- Validation on 2026-08-20: 833 tests passed, 42 tests were excluded, and total test coverage was 79.27% against a 75% project floor.
- Architecture validation: the cross-reference graph has no cycles, and the full `mix quality` gate passes.

## Status values

- `open`: Work has not started.
- `in_progress`: Work has started.
- `blocked`: A named dependency or decision blocks the task.
- `done`: The acceptance criteria and validation are complete.
- `superseded`: Another task now owns the work.

## Priority 0: trust and execution ownership

| ID | Task | Dependencies |
|---|---|---|
| L11-R1 | [Record approval progress for the exact gate](L11-R1-gate-specific-approval-progress.md) | None |
| L29-R1 | [Accept only a validated environment selection](L29-R1-validated-environment-selection.md) | L29-R2 |
| L29-R2 | [Use one complete contract walker](L29-R2-complete-contract-walker.md) | None |
| L35-R1 | [Give async chat one outbound event publisher](L35-R1-single-async-event-publisher.md) | L17-R1 |
| L21-R2 | [Restrict review to operation effects](L21-R2-operation-only-review.md) | None |
| L12-R1 | [Keep one timeout owner for each operation](L12-R1-single-operation-timeout-owner.md) | None |
| L18-R1 | [Make the lease request ID the current-work authority](L18-R1-lease-request-current-work.md) | L18-R2 |

## Priority 1: direct correctness and bounded resource use

| ID | Task | Dependencies |
|---|---|---|
| L23-R1 | [Compile each operation source once](L23-R1-atomic-operation-source-compilation.md) | L16-R1 |
| L24-R1 | [Make catalog limits host-owned ceilings](L24-R1-host-owned-catalog-limits.md) | L29-R2, L30-R1 |
| L21-R1 | [Normalize all policy callback results](L21-R1-total-policy-result-normalization.md) | None |
| L18-R2 | [Declare durable storage as none or complete](L18-R2-durable-store-capability-set.md) | None |
| L20-R1 | [Keep pending review in one place](L20-R1-single-pending-review-source.md) | L11-R1 |
| L08-R1 | [Use a safe model set before prompt compaction](L08-R1-safe-model-budget.md) | None |
| L10-R1 | [Store one operation-decision list](L10-R1-single-operation-decision-list.md) | L23-R1 |
| L27-R1 | [Keep one workflow suspension cursor](L27-R1-single-workflow-suspension-cursor.md) | None |
| L38-R2 | [Bound text-search memory while collecting](L38-R2-bounded-search-collector.md) | None |
| L30-R1 | [Normalize a process-extension manifest once](L30-R1-normalized-extension-manifest.md) | L29-R2 |
| L36-R1 | [Make evaluation assertions closed and typed](L36-R1-typed-eval-assertions.md) | None |
| L22-R2 | [Keep memory idempotency state private](L22-R2-private-memory-idempotency-index.md) | None |
| L19-R1 | [Keep updated session state in internal errors](L19-R1-retain-session-in-internal-errors.md) | None |
| L06-R1 | [Make public error maps portable](L06-R1-portable-error-projection.md) | None |
| D01-R1 | [Monitor the showcase turn worker](D01-R1-monitored-showcase-worker.md) | L34-R1 |
| D08-R1 | [Check the latest Lua execution](D08-R1-latest-lua-execution.md) | None |

## Priority 2: model and ownership cleanup

| ID | Task | Dependencies |
|---|---|---|
| L17-R1 | [Make async chat requests controller-only](L17-R1-controller-only-async-request.md) | None |
| L33-R1 | [Share only pure turn preparation](L33-R1-shared-pure-turn-preparation.md) | L08-R1, L23-R1 |
| L34-R1 | [Correlate AgentView state with one request](L34-R1-request-scoped-agent-view.md) | L17-R1, L35-R1 |
| L26-R1 | [Use Zoi as the workflow schema encoder](L26-R1-zoi-schema-authority.md) | None |
| L03-R1 | [Enforce role-specific message fields](L03-R1-message-role-validation.md) | None |
| L22-R1 | [Use one typed memory route](L22-R1-typed-memory-route.md) | None |
| L25-R1 | [Validate one canonical handoff identity](L25-R1-canonical-handoff-identity.md) | None |
| L09-R1 | [Remove copied turn state](L09-R1-single-turn-state-authority.md) | None |
| L14-R1 | [Scan streamed provider data once](L14-R1-incremental-provider-stream-scanner.md) | None |
| L28-R1 | [Separate live schedule state from history](L28-R1-active-schedule-run-index.md) | None |
| L38-R1 | [Compile ignore rules once per search](L38-R1-compiled-ignore-evaluator.md) | None |
| L16-R1 | [Resolve a skill specification once](L16-R1-resolve-skill-once.md) | None |

## Priority 3: lower-risk cleanup and guardrails

| ID | Task | Dependencies |
|---|---|---|
| L08-R2 | [Use one transcript cutoff calculation](L08-R2-linear-context-cutoff.md) | None |
| L09-R2 | [Remove unused plan phase fields](L09-R2-remove-unused-plan-phases.md) | L09-R1 |
| L26-R2 | [Enforce step-kind field rules](L26-R2-step-kind-field-validation.md) | None |
| D08-R2 | [Accept one customer-search selector](D08-R2-single-customer-search-selector.md) | None |
| T02-R1 | [Bound the parity restart wait](T02-R1-bounded-parity-restart-wait.md) | None |
| U02-R1 | [Give durable version facts one documentation source](U02-R1-durable-version-documentation-source.md) | None |

## Recommended first slices

1. L11-R1: exact gate approval.
2. L29-R2: complete contract walking.
3. L29-R1: validated environment selection.
4. L12-R1: remove the duplicate Runic timeout.
5. L16-R1 and L23-R1: resolve and compile each source once.
6. L17-R1 and L35-R1: one async request owner and one outbound event path.
7. L38-R2: bounded search collection.
8. L26-R1 and L36-R1: schema corrections with small scopes.
9. L18-R2 before L18-R1.
10. L11-R1 before L20-R1.

## Task file contract

Each task must contain:

1. Stable ID and title.
2. Status, priority, impact, confidence, effort, blast radius, and dependencies.
3. Exact code evidence.
4. The current invalid state, duplicate work, or ownership split.
5. The proposed representation and its invariant.
6. The smallest credible implementation scope.
7. Regression and migration risks.
8. Existing and new validation.
9. Acceptance criteria.
10. Explicit out-of-scope work.

## Audit exclusions

The audit rejected proposals that only moved branches, changed style, added hypothetical extension points, or caused a public migration without a demonstrated invalid state. It also merged duplicate findings into the task that owns the relevant data or lifecycle.
