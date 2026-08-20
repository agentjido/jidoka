---
id: L11-R1
title: Store approval progress for the exact gate
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P0
impact: critical
confidence: high
effort: medium
blast_radius: medium
dependencies: []
---

# Store approval progress for the exact gate

## Objective

Make an approval apply only to the exact control or policy gate that created it.

## Evidence

- `lib/jidoka/runtime/review.ex:122-137` stores one scalar approval identifier.
- `lib/jidoka/runtime/controls/operation.ex:22-82` skips controls after that scalar is present.
- `lib/jidoka/policy/gate.ex:115-122,286-290` accepts the same scalar for a host policy review.
- `lib/jidoka/runtime/effect_interpreter.ex:90-109,205-216` resumes effect handling after review.

## Current problem

Approval for one rule can skip a later rule or the host gate. The scalar does not identify the gate that consumed it.

## Proposed representation and invariant

Store portable approval progress keyed by the exact intent ID, gate identity, and interrupt ID. A resumed approval can satisfy only its recorded gate. Evaluation continues at the next gate.

## Smallest credible scope

- Change review progress in `runtime/review.ex`.
- Update operation controls, policy gate, and effect interpreter.
- Update journal or snapshot data that stores approval progress.
- Keep a compatibility decoder for the old scalar form.

## Risks and migration

Old snapshots contain a scalar approval value. Convert it conservatively, or require re-review when exact gate identity is unavailable. Do not re-run controls that already completed.

## Validation

Run existing HITL, policy-gate, resumable-approval, and crash-safe parity tests.

Add cases:

- approve rule A, then evaluate rule B -> rule B still runs;
- approve an operation gate, then reach host review -> host review still interrupts;
- resume with forged interrupt ID -> typed rejection;
- resume exact approval -> no completed control runs again.

## Acceptance criteria

- No approval can authorize a different gate.
- Stored progress identifies the approved gate.
- Legacy persisted data has a defined safe behavior.
- Existing valid approval flows still resume.

## Out of scope

- New policy decision kinds.
- Changes to the review user interface.
