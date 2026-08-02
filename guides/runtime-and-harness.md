# Runtime And Execution Layers

This is a maintainer guide for the internal execution layers. Application code
must use the `Jidoka` facade and the public data contracts instead of these
modules.

Jidoka separates authoring, executable data, and effect execution.

## When To Use This

- Use this guide when you maintain the turn runner, session execution, review
  execution, or an adapter.
- Use this guide when you must trace dependency direction through an internal
  execution path.
- For application development, start with [Getting Started](getting-started.md)
  and [Public Facade](public-facade.md).

```text
Jidoka.Agent DSL
-> Jidoka.Agent.Spec
-> Jidoka.Turn.Plan
-> Jidoka.Turn.Execution
-> Jidoka.Runtime.TurnRunner
-> Jidoka.Adapter.Runic.TurnCompiler
-> pure spine steps
-> Effect interpreter
-> Jidoka.Adapter.ReqLLM / Jidoka.Operation.Source
```

For process-hosted agents, `Jido.AgentServer` sits around the same turn use
case:

```text
Jido.AgentServer
-> Jido.Signal "jidoka.turn.run"
-> Jidoka.Adapter.Jido.RunTurn
-> Jidoka.Turn.Execution
-> Jido agent state update
```

## Execution Use Cases

Three modules own execution workflows:

- `Jidoka.Turn.Execution` owns direct turns, request normalization, runtime
  capabilities, memory setup, and snapshot resume.
- `Jidoka.Session.Execution` owns session creation, leases, checkpoints,
  recovery, forks, replay, and session memory.
- `Jidoka.Review.Execution` owns pending review lists and approval or denial
  resume work.

`Jidoka.Harness` is now a thin compatibility delegate. New internal code calls
the owner module. Normal application code uses `Jidoka` and `Jidoka.Session`.

## Sessions And Stores

`Jidoka.Session` is the ergonomic API for durable sessions. It delegates to
`Jidoka.Session.Execution`. The underlying data struct is
`Jidoka.Session.Data`.

`Jidoka.Session.Data` is the durable session envelope for work that spans
requests or process restarts. It contains:

- the canonical agent spec;
- request history;
- hibernated snapshots;
- pending review requests;
- the latest result or error;
- optional fork lineage;
- metadata owned by the application.

Sessions are still data. They do not contain runtime clients or processes.

```elixir
{:ok, pid} = Jidoka.Session.Store.InMemory.start_link()
store = {Jidoka.Session.Store.InMemory, pid: pid}

{:ok, session} =
  Jidoka.session(spec, "support-session-1", store: store)

{:hibernate, session, snapshot} =
  Jidoka.Session.run(session.session_id, "Hello",
    store: store,
    llm: llm,
    checkpoint: :after_prompt
  )

{:ok, session, result} =
  Jidoka.Session.resume(session.session_id,
    store: store,
    llm: llm
  )

{:ok, branch} =
  Jidoka.Session.fork(session,
    session_id: "support-session-1-alternate"
  )
```

A fork copies one stored, safe hibernation snapshot into a new session. It
keeps the effect journal, records root and parent lineage, and leaves the
source session unchanged. It does not support arbitrary state editing,
cursor movement, or effect re-execution.

The base store behaviour is small: put/get/list sessions. Lease-aware adapters
also implement claim, resume claim, checkpoint, renewal, recovery, and commit
transitions. Pending review listing is derived from stored session data:

```elixir
{:ok, reviews} = Jidoka.Session.pending_reviews(store)
```

Replay is a projection over stored data, not a runtime call. Fork is the
separate API that creates a runnable branch:

```elixir
{:ok, replay} = Jidoka.Session.replay(session)
replay.timeline
replay.lineage
```

For crash recovery, `Jidoka.Session.recoverable/2` lists expired leased work
that has a durable snapshot. `Jidoka.Session.recover/2` atomically takes a new
lease and resumes it. `Jidoka.Session.Store.Dets` provides a synced,
single-node disk adapter. A multi-node deployment can implement the same store
callbacks with database compare-and-set transactions.

Replay diagnostics explain whether recorded effects are complete and safe to
reason about without calling providers or tools:

```elixir
{:ok, diagnostics} = Jidoka.Session.Replay.diagnose(replay)

diagnostics.status
#=> :complete | :waiting | :failed | :incomplete

diagnostics.missing_effect_results
diagnostics.unsafe_effects
diagnostics.pending_reviews
```

Diagnostic statuses are intentionally small:

| Status | Meaning |
| --- | --- |
| `:complete` | The replay has complete effect result data. |
| `:waiting` | Human review is pending, usually from an interrupted operation control. |
| `:failed` | At least one effect result or timeline event failed. |
| `:incomplete` | An effect intent exists without a recorded result. |

Use `Jidoka.Debug.request/2` when you want a request-level view that combines
prompt metadata, operation results, usage, timeline, journal, and replay
diagnostics:

```elixir
{:ok, summary} = Jidoka.Debug.request(result)
summary.prompt.messages
summary.replay_diagnostics.status
```

For hibernated work, pass the snapshot directly. Add `session:` when you want
the session id attached to the summary:

```elixir
{:hibernate, session, snapshot} = Jidoka.Session.run(session, "Refund A1001")

{:ok, summary} = Jidoka.Debug.request(snapshot, session: session)
summary.pending_reviews
summary.replay_diagnostics.status
```

## Observability And Evals

Core runtime events are neutral `Jidoka.Event` data. `Jidoka.Trace` projects
them into a compact timeline, and callers decide whether to persist that
timeline:

```elixir
{:ok, sink} = Jidoka.Trace.Sink.InMemory.start_link()

:ok =
  Jidoka.Trace.record(result.events, {Jidoka.Trace.Sink.InMemory, pid: sink},
    policy:
      Jidoka.Trace.Policy.new!(
        sample_rate: 1.0,
        redact_keys: [:api_key, :authorization],
        omit_keys: [:messages, :prompt]
      )
  )
```

`Jidoka.inspect/1` returns stable views for agents, turns, snapshots, sessions,
replay, effect journals, review objects, memory results, and eval runs. These
views are projection-oriented and avoid provider-specific client data.

Eval cases are deterministic harness fixtures:

```elixir
{:ok, run} =
  Jidoka.Eval.run_case(
    [
      id: "support_lookup",
      agent: spec,
      input: "Check account acct_123",
      assertions: %{
        contains: "acct_123",
        operation_called: "lookup_account"
      }
    ],
    llm: llm,
    operations: operations
  )
```

The eval runner does not add another agent runtime. It uses
`Jidoka.Turn.Execution.run/3`, then records assertion results and observations
on `Jidoka.Eval.Run`.

Eval input validation and eval execution failures are intentionally different:

- invalid eval case data returns `{:error, reason}`;
- a harness runtime error returns `{:ok, %Jidoka.Eval.Run{status: :error}}`;
- a hibernated turn also returns `{:ok, %Jidoka.Eval.Run{status: :error}}`
  with `%{reason: :hibernated, snapshot: ...}` in `run.error`.

That keeps eval outcomes serializable as evidence while still rejecting invalid
eval definitions before execution.

## Memory

Memory is opt-in agent policy plus per-run store capability:

```elixir
spec =
  Jidoka.agent!(
    id: "support_agent",
    instructions: "Use recalled memory when useful.",
    memory: %{scope: :session, max_entries: 5}
  )

{:ok, pid} = Jidoka.Memory.Store.InMemory.start_link()
memory_store = {Jidoka.Memory.Store.InMemory, pid: pid}

{:ok, _write} =
  Jidoka.Session.Execution.write_memory(spec, "Ada prefers concise answers.",
    memory_store: memory_store
  )
```

Before prompt assembly, turn execution recalls memory through the supplied store
and passes a typed `Jidoka.Memory.RecallResult` into the Runic turn state.
Prompt assembly then:

- adds a `memory_recalled` trace event when entries are present;
- adds a compact "Relevant memory" system message;
- exposes `prompt.memory` for preflight, tests, and provider runtime code.

`Jidoka.preflight/3` accepts the same `memory_store:` option, so memory
contributions are visible without calling an LLM.

## Operation Sources

Jidoka keeps one runtime operation path. Different executable surfaces should
compile into `Agent.Spec.Operation` plus a capability function:

```elixir
source =
  Jidoka.Operation.Source.Local.new!(
    operations: [
      %{
        name: "lookup_ticket",
        description: "Looks up a ticket.",
        kind: :tool,
        handler: fn args, _ctx -> %{ticket_id: args["ticket_id"], status: "open"} end
      }
    ]
  )

{:ok, compiled} = Jidoka.Operation.Source.compile(source)

spec =
  Jidoka.agent!(
    id: "support_agent",
    instructions: "Use lookup_ticket when needed.",
    operations: compiled.operations
  )

Jidoka.turn(spec, "Check ticket T-100",
  llm: llm,
  operations: compiled.capability
)
```

Controls still match by operation `kind` and `name`. The local source above
uses kind `:tool`; Jido action sources use kind `:action`. Both execute through
the same `Effect.Intent` / `Effect.Result` journal path.

## Turn Runner

`Jidoka.Runtime.TurnRunner` owns the loop:

1. run input controls;
2. run the Runic prompt/effect planning workflow;
3. optionally hibernate at a safe checkpoint;
4. interpret pending effects through runtime capabilities; independent
   operation batches run through Runic with bounded concurrency;
5. apply effect results to turn state;
6. validate and optionally repair structured final results;
7. loop until final answer or max model turns;
8. run output controls before returning.

Operation controls run inside the effect interpreter immediately before an
operation capability is called. If a control returns `{:interrupt, reason}`, the
runner marks the turn state as `:waiting` and hibernates at a review cursor
instead of calling the operation.

When one LLM decision returns multiple operation calls, Jidoka keeps the
model's order in `pending_effects`, preflights controls for the batch, then
executes allowed operations in parallel. `:max_parallel_operations` can be
passed to `turn/3` / `resume/2`, or configured globally with
`:default_max_parallel_operations`. Checkpoint policies `:after_each_phase` and
`:before_each_effect` keep the older one-effect-at-a-time pause behavior for
debugging and durable replay.

## Effects

External work is represented as data:

```elixir
%Jidoka.Effect.Intent{
  kind: :llm | :operation,
  payload: %{},
  idempotency_key: "...",
  idempotency: :idempotent
}
```

The effect interpreter records intents and results in `Effect.Journal`. On
resume, existing results are reused instead of re-running the same effect.
During a lease-backed session run, the harness also saves a snapshot after the
intent and after the result. The result checkpoint is durable before the turn
applies the result.

## Operation Idempotency

Every operation declares one idempotency policy:

- `:pure` means the operation can be recomputed from input;
- `:idempotent` means the runtime can safely retry with the same key;
- `:dedupe` means Jidoka should prefer a recorded journal result;
- `:reconcile` means incomplete work should be surfaced for application
  reconciliation;
- `:unsafe_once` means Jidoka must not retry automatically.

`:unsafe_once` operations require either an approval policy or an explicit
operation control. This makes risky work visible at preflight time instead of
discovering it after a model chooses the operation.

On recovery, incomplete `:dedupe` and `:reconcile` intents do not run
automatically. Incomplete `:unsafe_once` intents also stop. Only `:pure` and
`:idempotent` effects are automatic retry candidates, and they keep the same
idempotency key.

If a journal already has a result for an operation effect, resume replays that
result and does not call the operation capability again. If an `:unsafe_once`
intent was recorded without a result, resume returns a typed execution error
instead of retrying the operation. Later harness/session storage can use that
same shape to route the case to a reconciliation queue.

## Durability

Jidoka snapshots semantic state:

```elixir
{:hibernate, snapshot} =
  Jidoka.turn(spec, "Hello",
    llm: llm,
    checkpoint: :after_prompt
  )

{:ok, result} = Jidoka.resume(snapshot, llm: llm)
```

Current checkpoint policies:

- `:none`
- `:after_prompt`
- `:after_each_phase`
- `:before_each_effect`

This is safe-boundary durability, not arbitrary process resurrection.

Versioned durability boundaries:

- `Jidoka.Snapshot.schema_version() == 1`;
- serialized snapshots use the opaque prefix `jidoka:snapshot:v1:`;
- `Jidoka.Session.Data.schema_version() == 1`;
- import documents use `Jidoka.Import.AgentDocument.version() == 1`.

Unsupported versions fail during normalization instead of attempting a partial
resume/import.

## Human-In-The-Loop Review

An operation control can pause execution:

```elixir
def call(%Jidoka.Runtime.Controls.OperationContext{} = operation) do
  if operation.operation == "refund_order" do
    {:interrupt, :approval_required}
  else
    :cont
  end
end
```

The returned snapshot has:

- `cursor.phase == :review`;
- `turn_state.status == :waiting`;
- `turn_state.pending_interrupt` as a `Jidoka.Review.Interrupt`;
- `metadata["pending_review"]` as a `Jidoka.Review.Request`.

Resume with an approval response:

```elixir
approval = Jidoka.Review.Response.approve(snapshot.turn_state.pending_interrupt)
{:ok, result} = Jidoka.resume(snapshot, approval: approval, llm: llm, operations: operations)
```

Resume with a denial:

```elixir
denial = Jidoka.Review.Response.deny(snapshot.turn_state.pending_interrupt, reason: :rejected)
{:error, error} = Jidoka.resume(snapshot, approval: denial, llm: llm, operations: operations)
```

The approved operation resumes from the pending `Effect.Intent`; Jidoka does
not re-run operation controls for that approved interrupt. The journal still
prevents duplicate effect results on normal hibernate/resume boundaries.

## Structured Results

If `Agent.Spec.result` is present, a final model decision must include a
structured `result` value in addition to user-facing `content`:

```elixir
%{
  type: :final,
  content: "Ada is ready.",
  result: %{name: "Ada", confidence: 10}
}
```

The runtime validates the value with the configured Zoi schema before marking
the turn finished. Validated data is stored on `Turn.State.result_value` and
returned as `Turn.Result.value`. Output controls run after validation, so their
context receives both `result` text and `result_value` data.

If a model omits the explicit `result` field but returns JSON as `content`,
Jidoka attempts to validate that decoded JSON as the structured result. Plain
text content is still preserved for unstructured agents.

If validation fails and `max_repairs` has not been exhausted, Jidoka appends a
repair instruction to the durable agent state and runs another model turn. This
uses the same Runic/effect loop; it is not a provider-specific structured output
API.

## Jido Relationship

Jidoka uses Jido as the foundation:

- DSL agent modules are also `Jido.Agent` modules;
- tools are Jido actions;
- action schemas and execution stay on the Jido side.
- `Jidoka.Jido` is the default Jido runtime instance started by the Jidoka
  application module.
- `MyAgent.start/1` and `Jidoka.start_agent/2` start DSL agents under
  `Jido.AgentServer`.
- AgentServer routes `"jidoka.turn.run"` to `Jidoka.Adapter.Jido.RunTurn`,
  which runs the Jidoka harness and writes `:status`, `:last_answer`, and
  a typed `Jidoka.Adapter.Jido.AgentServerState` under `agent.state[:jidoka]`.

Jidoka does not delegate the core loop to `Jido.AI.ReAct`. The ReAct-style loop
is implemented through Jidoka's Runic/effect/harness spine.
