# Concepts

Jidoka models a coding task as durable data plus a small OTP runtime. The runtime
can stream live updates, but persisted structs remain the source of truth.

## Session

A session is the durable envelope for one workspace. It owns workspace identity,
the run index, event history, and snapshot metadata.

## Run

A run is one submitted coding task. It owns the task text, task pack, lifecycle
status, latest attempt, artifact references, and final outcome.

Common run statuses are:

- `queued`
- `running`
- `awaiting_approval`
- `completed`
- `failed`
- `canceled`

## Attempt

An attempt is one execution pass for a run. It owns the execution input snapshot,
environment lease, execution status, progress metadata, artifacts, and
verification result reference.

## Environment Lease

An environment lease records which workspace path an attempt may use. The MVP
uses an exclusive local lease so mutation remains explicit and bounded.

## Verifier

A verifier adapter inspects an attempt output and returns a typed verification
result:

- `passed`
- `retryable_failed`
- `terminal_failed`

Verification and operator approval gate successful completion.

## Artifact

Artifacts are durable records emitted by execution or verification. Initial
artifact types include diffs, transcripts, command logs, verifier reports, and
prompt reports.

## Outcome

An outcome records the final operator decision for a run. Runs can be approved,
rejected, retried, canceled, or marked as failed depending on execution and
verification state.

## Events And Snapshots

Events are append-only facts emitted by the runtime. Snapshots are derived read
models for API consumers, CLIs, and future UIs.
