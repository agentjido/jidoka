# Capability fixture replay

Jidoka capability fixtures let a test run the normal turn or session-sequence
runtime without a live model, tool provider, policy service, or execution
environment. A fixture records public normalized exchanges. It does not record
raw provider traffic or executable capabilities.

Use fixture replay only when the input and the required compatibility data are
the same. Replay gives exact recorded responses. It does not prove that a model
or provider is deterministic.

## Record a fixture

Create the normal public capability bundle, start a recorder, and wrap the
bundle:

```elixir
alias Jidoka.Replay.Capabilities, as: ReplayCapabilities
alias Jidoka.Replay.Recorder
alias Jidoka.Runtime.Capabilities

live = Capabilities.new!(llm: llm, operations: operations, policy: policy)

{:ok, recorder} =
  Recorder.start_recording(
    compatibility: %{"agent" => "support-v1"},
    redact_strings: [System.fetch_env!("TEST_SECRET")]
  )

recorded = ReplayCapabilities.record(live, recorder)
{:ok, result} = Jidoka.Session.run_sequence(session, requests, capabilities: recorded)
{:ok, fixture} = Recorder.fixture(recorder)
{:ok, json} = Jidoka.Replay.Fixture.encode_json(fixture)
```

The optional string list redacts matching response text before it enters the
fixture. It is not stored. Credential-like map keys are always redacted. Live
values, such as functions, processes, ports, references, and runtime handles,
are rejected.

## Replay a fixture

Decode and verify the fixture. Then, build capabilities that have no live
delegate:

```elixir
{:ok, fixture} = Jidoka.Replay.Fixture.decode_json(json)

{:ok, player} =
  Recorder.start_replay(fixture, compatibility: %{"agent" => "support-v1"})

replayed = ReplayCapabilities.replay(player)
{:ok, result} = Jidoka.Session.run_sequence(session, requests, capabilities: replayed)
:ok = Recorder.finish(player)
```

`finish/1` is necessary. It detects fixture entries that the run did not use.
A call also fails if its class, action, fingerprint, or order differs. A call
after the last entry fails as a missing call. These mismatches do not call a
live capability.

## Fixture contract

A version 1 fixture has these fields:

| Field | Meaning |
| --- | --- |
| `version` | Fixture schema version. |
| `compatibility` | Caller-declared data that must match before replay. |
| `entries` | Ordered capability exchanges. |
| `redaction` | Redaction method facts. |
| `digest` | SHA-256 digest of all other fixture fields. |

Each entry has a global `index`, a capability `class`, an `action`, an input
`fingerprint`, a per-fingerprint `occurrence`, an `outcome`, a portable encoded
`response`, and recording evidence. The classes are `llm`, `operation`,
`policy`, and `environment`. The request body is not stored. Its normalized,
redacted data contributes only to the fingerprint. Run-local `run_id`,
`cell_id`, `session_id`, `request_id`, `intent_id`, and `effect_id` fields do not
contribute. Thus, equivalent inputs can use one fixture in separate fresh
sessions. Model, prompt, operation arguments, policy resource, and other
semantic fields still contribute.

The player verifies the digest, indexes, unique occurrence keys, data types,
and compatibility data before it starts. Unknown encoded atoms, malformed
data, changed input, and unsupported versions fail closed.

## Environment lifecycle calls

An environment adapter can wrap each public normalized lifecycle callback:

```elixir
result =
  Jidoka.Replay.Environment.record(recorder, :open, policy_request, fn ->
    adapter.open(profile, policy_request, opts)
  end)
```

During replay, call `Jidoka.Replay.Environment.replay/3` with the same action
and normalized request. Supported actions are `open`, `acquire`, `checkpoint`,
`restore`, `fork`, `close`, `cleanup`, and `execute`.

Replayed enforcement evidence gets `facts.evidence_source = "recorded"` and
`facts.live = false`. Its original status describes the recorded call only. It
is not current live-enforcement proof. Never store an adapter handle in the
request or response fixture data. Use a portable binding or checkpoint fact.

## Terminal behavior

The wrapper returns the same recorded success or error through the normal
runtime. Thus, model errors, operation errors, policy denials, cancellation,
and environment cleanup errors use the normal Jidoka terminal contracts.
Hibernation before a capability call produces no fixture entry and replays with
the same checkpoint option.

The effect journal still owns idempotency. The sequence runtime still owns turn
order and semantic state. Fixture replay does not bypass either contract.
