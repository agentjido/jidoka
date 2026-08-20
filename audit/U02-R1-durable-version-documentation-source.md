---
id: U02-R1
title: Durable version documentation source
status: done
completed_at: 2026-08-20
implementation_commit: 29246d0a
priority: P3
impact: high
confidence: high
effort: low-medium
blast_radius: low-medium
dependencies: []
---

# Durable version documentation source

## Objective

Make durable schema versions and documented compatibility facts come from one
checked source.

## Evidence

- `lib/jidoka/snapshot.ex:19` sets snapshot schema version 2.
- `lib/jidoka/session/data.ex:21` sets session schema version 3.
- `lib/jidoka/snapshot/codec.ex:4` uses an independent v1 codec prefix.
- `guides/snapshots-and-resume.md:78` states an old schema version.
- `guides/import-and-snapshot-contracts.md:135` and `:157` state durable
  compatibility facts.

## Current problem

The guides can confuse schema versions with codec-prefix versions. Version facts
are duplicated in implementation and documentation, so they can drift without a
documentation check failure.

## Proposed representation and invariant

Expose small compatibility accessors for current and accepted snapshot and
session schema versions. Keep codec prefix as a separate fact. Make the
documentation check read these accessors or a generated facts input. Every guide
table must match the durable contract.

## Smallest credible scope

- `lib/jidoka/snapshot.ex`.
- `lib/jidoka/session/data.ex`.
- `lib/jidoka/snapshot/codec.ex` only for explicit separate documentation.
- `scripts/check_docs.exs`.
- `guides/snapshots-and-resume.md`, `guides/import-and-snapshot-contracts.md`,
  and `guides/runtime-and-harness.md`.
- Existing legacy decode and documentation-check tests.

Do not change any encoded snapshot or codec value.

## Risks and migration

The main risk is accidental codec change while adding accessors. Keep current
wire values unchanged. Document current and accepted versions separately from
the codec prefix.

## Validation

Run existing legacy snapshot decode tests and the documentation checker.

- Input: a guide with wrong snapshot schema version. Expected: documentation
  check fails with the mismatched fact.
- Input: a guide with wrong session schema version. Expected: check fails.
- Input: a guide that treats codec prefix as schema version. Expected: check
  fails or separate labels make the mismatch clear.
- Input: legacy snapshot. Expected: current decode behavior remains unchanged.

## Acceptance criteria

- Current and accepted durable schema versions have one authoritative source.
- Codec prefix is documented as a separate wire fact.
- Documentation checking detects version drift.
- No durable wire value changes.

## Out of scope

- A new snapshot codec.
- Changes to snapshot retention or replay behavior.
