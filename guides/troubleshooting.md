# Troubleshooting

This appendix lists the failure modes that surface from Jidoka's data,
import, runtime, operation, hibernation, process-hosting, and memory paths.
Each row pairs the visible symptom with the most likely cause and the
preferred fix. The categories follow the same order a turn flows through:
authoring data first, runtime second, durable state last. Use the diagnostic
workflow at the end of the guide when the matching category is not obvious
from the error tuple alone.

## When To Use This

- Use this guide when a `Jidoka.turn/3`, `Jidoka.chat/3`,
  `Jidoka.import/2`, or `Jidoka.resume/2` call returns an error tuple and
  you need to triage quickly.
- Use this guide when a process-hosted agent does not behave as expected.
- Use this guide as the first lookup before reading
  [Errors And Config Reference](errors-and-config-reference.md), which
  documents the typed error structs in depth.
- Do not use this guide as a tutorial. Start with [Getting Started](getting-started.md).

## Prerequisites

- Elixir `~> 1.18` and a project that depends on `:jidoka`.
- A failing call you can re-run while iterating.
- For live failures: a provider key in scope.

```bash
mix deps.get
mix test
```

## Concepts

Three ideas frame the rest of this guide.

1. **Errors are normalized through `Jidoka.Error.normalize/2`.** Every facade
   call returns either a tuple with a normalized Splode error or a tuple
   with a small classified atom. Tuples like `{:error, {:max_model_turns_exceeded, n}}`
   are intentional; they make pattern matching in callers possible.
2. **Most failures happen at one of five seams:** DSL compile, import,
   capability call, control, snapshot serialize/restore. The table headings
   below mirror those seams.
3. **The runtime never hides a failure.** A `:turn_failed` event is emitted
   for every failed turn, the journal still records the intent that was in
   flight, and the snapshot (when one was taken) is still valid.

```diagram
        Author/Import time            Runtime time              Durable time
        ────────────────────         ──────────────             ────────────
        DSL compile / import         capability calls          snapshot serialize
        registry resolution          controls, review          AgentServerState
        Spec/Plan validation         retries/repair            memory store
        |                            |                         |
        ▼                            ▼                         ▼
        category: Authoring,         category: Runtime,        category: Hibernation,
                  Import                       Operation,                Process,
                                              Control                    Memory/Trace
```

## How To

### Step 1: Read The Error Tuple

Every Jidoka error has one of three shapes:

- `{:error, %Jidoka.Error{...}}` for normalized Splode errors with
  `:operation`, `:phase`, and `:context` set.
- `{:error, {:atom_tag, ...args}}` for runtime control-flow signals like
  `{:max_model_turns_exceeded, n}` or `{:turn_timeout_exceeded, ms, elapsed}`.
- `{:error, term}` for adapter-specific errors that have not yet been
  normalized; treat these as bugs worth reporting.

`Jidoka.format_error/1` and `Jidoka.error_to_map/1` are safe to use on any
of the three.

### Step 2: Match The Category Table

Find the row whose symptom matches the failure. Categories are ordered by
when the failure typically appears.

### Step 3: Use The Diagnostic Workflow

When no row matches, follow the diagnostic workflow at the end of this guide.
Most production failures are reproducible with a deterministic turn plus a
trace.

## Common Patterns

- **Add the failing input to a test before fixing.** A test that reproduces
  the error against a fake LLM is the fastest way to validate a fix.
- **Inspect, then preflight, then turn.** `Jidoka.inspect/1` exposes the
  spec and plan; `Jidoka.preflight/3` exposes the prompt and diagnostics.
  Most authoring and import errors surface there before any provider call.
- **Read the timeline, not the raw event list.** `Jidoka.inspect/1` of a
  `Turn.Result` or snapshot already includes a stable trace timeline.
- **Re-run with `mix test --include live` before blaming the provider.** A
  failing live test against the latest model is the cheapest reproduction.

## Authoring Errors

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `(Spark.Error.DslError)` at compile time | DSL section missing a required field | Read the Spark error; add the missing `model`, `name`, or schema. |
| Compile error: `unknown option :tools` inside `agent do` | `tools` is a sibling section, not nested under `agent` | Place `tools do ... end` next to `agent do ... end`, not inside it. |
| `Jidoka.Agent.Spec.new!/1` raises `ArgumentError` | Invalid spec data passed at runtime | Wrap in `Jidoka.agent/1` (returns `{:ok, _}`/`{:error, _}`); inspect the reason. |
| `{:error, {:invalid_zoi_schema, _}}` on context/result | Schema is not a Zoi schema | Use `Zoi.object/1`, `Zoi.string/0`, etc.; do not pass a raw map. |
| `Jidoka.preflight/3` returns `{:error, {:missing_default_model, _}}` | Neither agent nor `Jidoka.Config.default_model/0` is set | Set `model` in the DSL or configure `:jidoka, :default_model`. |
| Operation in DSL has `idempotency: :unsafe_once` but turn errors with `{:operation_policy_violation, _}` | No operation control attached to the unsafe operation | Add a `controls` entry that matches the operation with a `Jidoka.Control` implementation. |
| `(ArgumentError) invalid agent spec: ...` from `Jidoka.agent!/1` | Tests passing raw atoms or unsupported keys | Use `Jidoka.agent/1`, surface `{:error, reason}` instead of raising. |
| Compile warning about `unused alias` in the agent module | DSL macro generated the alias automatically | Either remove the explicit alias or suppress with `_ = MyAction`. |
| Memory section accepted but never used | Memory adapter not passed at runtime | Pass `memory_store:` to `Jidoka.turn/3` or configure a default. |

## Import Errors

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, %Jidoka.Error.Invalid{message: "missing action registry"}}` | YAML references an action without a matching `actions:` registry | Pass `actions: %{"name" => ModuleMod}` to `Jidoka.import/2`. |
| `{:error, {:unsupported_snapshot_schema_version, got, expected}}` | Snapshot was produced by a newer/older Jidoka version | Migrate the snapshot or refuse the resume; do not coerce. |
| `{:error, {:invalid_module_ref, ref}}` | Import contains a module reference that is not a string | Strings only; never put atoms or `String.to_atom/1` calls into the importer. |
| `{:error, {:missing_registry, :controls}}` | YAML references a control without a registry | Provide a `controls:` map; never auto-derive from string. |
| `{:error, {:unsafe_ref, ref}}` | Import tried to resolve a ref through `String.to_atom/1` | Use only the caller-provided registries; the import path never atomizes input. |
| `Jidoka.import/2` succeeds but `Jidoka.turn/3` fails with missing operation | Action ref resolved to a module that does not implement `to_tool/0` | Use a `Jidoka.Action` module or supply a custom operation source. |
| YAML version `1.x` accepted on a `1.y` runtime, breaks at runtime | Forward-compatible YAML schema let a new field through | Add a verifier; reject unknown top-level keys explicitly. |

## Runtime Errors

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, :missing_provider_credentials}` | Live turn without a provider key | Export `OPENAI_API_KEY`/`ANTHROPIC_API_KEY` or pass `llm: Jidoka.Runtime.ReqLLM.llm(model: ..., ...)` with explicit options. |
| `{:error, :empty_llm_response}` | Provider returned no text | Check provider/network; lower temperature; verify the prompt is not blocked. |
| `{:error, {:invalid_llm_decision_type, type}}` | Model emitted `"type"` Jidoka does not recognize | Tighten the prompt; or, if the new type is reasonable, extend `Jidoka.Runtime.ReqLLM.Decision.parse_object/1`. |
| `{:error, {:invalid_final_content, _}}` | Model emitted `"type": "final"` without a `"content"` string | Strengthen the prompt; consider lowering `max_repairs` to fail fast while iterating. |
| `{:error, {:invalid_operation_name, _}}` | Decision had a non-string operation name | The runtime cannot dispatch; fix prompt to force a string name. |
| `result.value` is `nil` after a `result` schema was declared | Model returned no structured `result` and `content` was not JSON | Read `Structured Results` guide; lower `max_repairs` to surface early; tighten prompt. |
| `{:error, {:max_model_turns_exceeded, n}}` | Loop never produced a `:final` decision within `n` turns | Raise `max_turns` in `controls` or strengthen the prompt to converge. |
| `{:error, {:turn_timeout_exceeded, ms, elapsed}}` | A capability call blocked past `plan.timeout_ms` | Lower latency, raise the timeout, or move long work into an async operation pattern. |
| `{:error, {:invalid_capability_result, other}}` | Adapter returned something other than `{:ok, _}`/`{:error, _}` | Wrap return values in `{:ok, value}`; never return raw maps. |
| `{:error, :missing_pending_effect}` | Resume called against state with no pending intent | Verify the snapshot status; only `:waiting` snapshots with a pending interrupt are resumable through the approval path. |
| `:turn_failed` event missing from trace | Error returned outside the runner's `maybe_emit_turn_failed/4` helper | File a bug; every facade error path should emit `:turn_failed` first. |

## Operation Errors

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, :missing_operations_capability}` | Agent has operations but call omitted `operations:` | Pass `operations: Jidoka.Runtime.JidoActions.operations(actions)` or `Jidoka.Runtime.LocalOperations.operations(handlers)`. |
| `{:error, {:missing_jido_action, name}}` | Decision asked for an action not registered in `Jido.Action` list | Add the action to the operations capability or rename in the prompt. |
| `{:error, {:missing_operation_handler, name}}` | Decision asked for a local operation not in the handler map | Add the handler or update the prompt. |
| `{:error, {:unsupported_effect_kind, kind}}` | Adapter was called with an intent kind it does not handle | Route only `:operation` intents to the operation adapter; route `:llm` intents to the LLM adapter. |
| `{:error, {:invalid_operation_handler, handler}}` | Local handler is not arity 1 or 2 | Use `fn args -> ... end` or `fn intent, journal -> ... end`. |
| Operation runs twice for the same intent | Code path bypassed `Effect.Journal.result_for/2` | Route the call through `Jidoka.Runtime.EffectInterpreter.interpret_pending/3`. |
| `{:error, {:unsafe_once_incomplete_effect, intent}}` | Resume of an `:unsafe_once` intent without approval | Supply an approved `Jidoka.Review.Response` whose `interrupt_id` matches; or treat the intent as failed and discard the snapshot. |
| Operation succeeds but `result.content` is `nil` | The agent did not loop again after the operation observation | Confirm the LLM returned `:final` after the observation; check the prompt. |

## Hibernation And Resume Errors

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, :invalid_snapshot_serialization}` | Deserialize received a non-prefixed string | Confirm the value came from `Jidoka.Runtime.AgentSnapshot.serialize/1`; do not hand-craft snapshot strings. |
| `{:error, {:unsupported_snapshot_schema_version, version, expected}}` | Snapshot version drift between writer and reader | Bump the schema and add a migration, or refuse the snapshot. |
| `{:error, {:non_serializable_snapshot_value, path, type}}` | A function, pid, port, or ref leaked into `Turn.State` | Move the value into a runtime capability; reference it by id. |
| `{:error, {:approval_interrupt_mismatch, expected, actual}}` | `Review.Response.interrupt_id` does not match the pending interrupt | Read `pending_review` metadata from the snapshot to look up the correct `interrupt_id`. |
| `{:error, {:approval_expired, id, responded_at, expires_at}}` | Approval arrived after the review window closed | Hibernate again, request a fresh interrupt, or raise `approval_ttl_ms`. |
| `{:error, {:approval_denied, response}}` | Reviewer denied the operation | The turn ends as denied; surface the reason to the user. |
| `{:error, :missing_approval_response}` | `Jidoka.resume/2` called without `:approval` or `:approval_response` | Pass the response or expect `{:hibernate, snapshot}` to be returned unchanged. |
| Resume against a `:waiting` snapshot returns the same snapshot | No approval response supplied (the no-op path) | This is intentional; supply an approval response to advance the turn. |

## Process Hosting Errors

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, :not_found}` from `Jidoka.turn/3` with a string id | Agent process is not running under the Jido tree | Start with `Jidoka.start_agent(MyApp.Agent, id: "agent-1")` or confirm `Jidoka.whereis("agent-1")`. |
| `{:error, :timeout}` from `Jido.AgentServer.call` | Turn took longer than the `:timeout` option (default 30s) | Raise `timeout:` on `Jidoka.turn/3` or shorten the capability path. |
| `{:error, {:unexpected_jidoka_agent_state, _}}` | `AgentServerState.to_run_result/1` got a status it does not map | Add a `to_run_result/1` clause and a `jido_status/1` mapping for the new status. |
| Jido status stuck at `:working` | Agent crashed mid-turn before `Runtime.Actions.RunTurn` completed | Inspect supervisor logs; restart the agent process; re-run the turn. |
| Signal not routed to `Jidoka.Runtime.Actions.RunTurn` | Custom signal type registered without matching action | Use `Jidoka.Runtime.Signals.turn_run/2`; do not invent new types without adding actions. |
| `{:error, :missing_input}` from `RunTurn` | Signal carried an empty or non-string `input` | Ensure the signal data has `:input` set to a non-empty binary. |
| Agent never reaches `:completed` after a successful capability call | `RunTurn` returned a tuple instead of `{:ok, jido_state}` | The action must always return `{:ok, jido_state_map}`; failures are encoded in the map. |

## Memory And Trace Errors

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, :memory_store_unavailable}` | Memory enabled in spec but no store passed at runtime | Pass `memory_store:` to `Jidoka.turn/3` or configure a default in `Jidoka.Config`. |
| Recall returns empty entries despite written history | Scope mismatch between write and recall (`agent` vs `session`) | Confirm `Memory.scope` in the spec matches the lookup; use the same `session_id`. |
| Trace events missing fields like `agent_id` | Event built without merging defaults from `Jidoka.Event.build/3` | Use `Event.build/3` (or `Turn.Transition.event/3`); never hand-construct events. |
| Trace sink crashes on a new event name | Event added outside the shared `Jidoka.Event` vocabulary | Update `Jidoka.Event` and confirm `Jidoka.Trace.events/0` includes it. |
| Redacted key still appears in trace output | Redaction is configured at sink, not at the event | Configure `Jidoka.Trace.Policy.redact_keys` in the trace pipeline; do not filter inside the runner. |
| `Jidoka.inspect/1` of a memory recall returns raw entries | `Memory.RecallResult` lacks a `project/1` clause | Add a `Jidoka.Projection.project/1` clause and a `Jidoka.Inspection.inspect/2` view. |

## Diagnostic Workflow

When no row matches, follow this order. Each step is cheaper than the next.

1. **`Jidoka.inspect/1` on the agent module.** Confirms the spec compiled.
   ```elixir
   Jidoka.inspect(MyApp.TimeAgent)
   ```
2. **`Jidoka.preflight/3` with the failing input.** Confirms prompt assembly,
   memory contribution, and request normalization without any capability call.
   ```elixir
   {:ok, preflight} = Jidoka.preflight(MyApp.TimeAgent, failing_input)
   preflight.prompt.messages
   preflight.diagnostics
   ```
3. **Deterministic turn with a fake LLM.** Confirms the loop, controls, and
   journal work end to end without a provider.
   ```elixir
   llm = fn _intent, _journal -> {:ok, %{type: :final, content: "ok"}} end
   Jidoka.turn(MyApp.TimeAgent, failing_input, llm: llm)
   ```
4. **Live turn with a single iteration.** Cap `max_turns: 1` to surface
   provider errors without a long loop.
   ```elixir
   Jidoka.turn(MyApp.TimeAgent, failing_input, max_turns: 1)
   ```
5. **Trace timeline.** Use the result's events to identify the phase that
   failed.
   ```elixir
   result = Jidoka.inspect(turn_result)
   result.timeline
   ```

Most failures surface in the first two steps. The full sequence is rarely
needed once you have the categories above as a reference.

## Reference

- [`Jidoka`](`Jidoka`) - public facade, returns normalized errors from every
  call.
- [`Jidoka.Error`](`Jidoka.Error`) - Splode-backed error type and
  `normalize/2`, `format/1`, `to_map/1`.
- [`Jidoka.Runtime.TurnRunner`](`Jidoka.Runtime.TurnRunner`) - emits
  `:turn_failed` for every failed turn.
- [`Jidoka.Runtime.EffectInterpreter`](`Jidoka.Runtime.EffectInterpreter`) -
  source of unsafe-replay and capability errors.
- [`Jidoka.Runtime.Capabilities`](`Jidoka.Runtime.Capabilities`) - rejects
  invalid LLM/operations options at construction.
- [`Jidoka.Runtime.Review`](`Jidoka.Runtime.Review`) - validates approval
  responses and produces approval-related errors.
- [`Jidoka.Runtime.AgentSnapshot`](`Jidoka.Runtime.AgentSnapshot`) -
  serialization and version validation.
- [`Jidoka.Runtime.AgentServerState`](`Jidoka.Runtime.AgentServerState`) -
  maps `Jido.AgentServer` state back to `{:ok, _}`/`{:hibernate, _}`/`{:error, _}`.
- [`Jidoka.Trace`](`Jidoka.Trace`) - timeline
  projection used in the diagnostic workflow.
- [`Jidoka.Inspection`](`Jidoka.Inspection`) - implementation of
  `Jidoka.inspect/2` and `Jidoka.preflight/3`.

## Related Guides

- [Errors And Config Reference](errors-and-config-reference.md) - the
  authoritative reference for error structs and config keys.
- [Turn Runner And Effect Interpreter](turn-runner-and-effect-interpreter.md) -
  where the runtime errors originate.
- [Runtime Capabilities Internals](runtime-capabilities-internals.md) -
  adapter shapes that surface most operation and LLM errors.
- [Inspection And Preflight](inspection-and-preflight.md) - the tools the
  diagnostic workflow leans on.
- [Snapshots And Resume](snapshots-and-resume.md) - hibernation contract
  whose violations show up in the hibernation table.
- [Tracing And Events](tracing-and-events.md) - event vocabulary that the
  trace assertions in the workflow rely on.
