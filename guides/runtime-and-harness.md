# Runtime And Harness

Jidoka separates authoring, executable data, and effect execution.

```text
Jidoka.Agent DSL
-> Jidoka.Agent.Spec
-> Jidoka.Turn.Plan
-> Jidoka.Harness
-> Jidoka.Runtime.TurnRunner
-> Runic workflow steps
-> Effect interpreter
-> ReqLLM / Jido.Action
```

For process-hosted agents, `Jido.AgentServer` sits around that harness:

```text
Jido.AgentServer
-> Jido.Signal "jidoka.turn.run"
-> Jidoka.Runtime.Actions.RunTurn
-> Jidoka.Harness
-> Jido agent state update
```

## Harness

`Jidoka.Harness` is the execution boundary. It currently owns:

- `run_turn/3`;
- `resume/2`;
- request normalization;
- context schema validation;
- runtime normalization;
- approval response normalization;
- delegation to `Jidoka.Runtime.TurnRunner`.

The harness is intentionally thin. Future session queues, stores, replay,
approval flows, and eval fixtures belong here rather than in the root `Jidoka`
module.

## Sessions And Stores

`Jidoka.Session` is the ergonomic API for durable sessions. It delegates to
`Jidoka.Harness`, and the underlying data struct is still
`Jidoka.Harness.Session`.

`Jidoka.Harness.Session` is the durable harness envelope for work that spans
requests or process restarts. It contains:

- the canonical agent spec;
- request history;
- hibernated snapshots;
- pending review requests;
- the latest result or error;
- metadata owned by the application/harness.

Sessions are still data. They do not contain runtime clients or processes.

```elixir
{:ok, pid} = Jidoka.Harness.Store.InMemory.start_link()
store = {Jidoka.Harness.Store.InMemory, pid: pid}

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
```

The store behaviour is intentionally small: put/get/list sessions. Pending
review listing is derived from stored session data:

```elixir
{:ok, reviews} = Jidoka.Session.pending_reviews(store)
```

Replay is a projection over stored data, not a runtime call:

```elixir
{:ok, replay} = Jidoka.Session.replay(session)
replay.timeline
```

Replay diagnostics explain whether recorded effects are complete and safe to
reason about without calling providers or tools:

```elixir
{:ok, diagnostics} = Jidoka.Harness.Replay.diagnose(replay)

diagnostics.status
#=> :complete | :waiting | :failed | :incomplete

diagnostics.missing_effect_results
diagnostics.unsafe_effects
diagnostics.pending_reviews
```

Use `Jidoka.Debug.request/2` when you want a request-level view that combines
prompt metadata, operation results, usage, timeline, journal, and replay
diagnostics:

```elixir
{:ok, summary} = Jidoka.Debug.request(result)
summary.prompt.messages
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
`Jidoka.Harness.run_turn/3`, then records assertion results and observations on
`Jidoka.Eval.Run`.

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
  Jidoka.Harness.write_memory(spec, "Ada prefers concise answers.",
    memory_store: memory_store
  )
```

Before prompt assembly, the harness recalls memory through the supplied store
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
        handler: fn args -> %{ticket_id: args["ticket_id"], status: "open"} end
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
4. interpret pending effects through runtime capabilities;
5. apply effect results to turn state;
6. validate and optionally repair structured final results;
7. loop until final answer or max model turns;
8. run output controls before returning.

Operation controls run inside the effect interpreter immediately before an
operation capability is called. If a control returns `{:interrupt, reason}`, the
runner marks the turn state as `:waiting` and hibernates at a review cursor
instead of calling the operation.

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

## Operation Idempotency

Every operation declares one idempotency policy:

- `:pure` means the operation can be recomputed from input;
- `:idempotent` means the runtime can safely retry with the same key;
- `:dedupe` means Jidoka should prefer a recorded journal result;
- `:reconcile` means incomplete work should be surfaced for application
  reconciliation;
- `:unsafe_once` means Jidoka must not retry automatically.

`:unsafe_once` operations require an explicit operation control. The control
can allow, block, or interrupt for human review, but it must be present before
the spec can be compiled into a `Turn.Plan`. This makes risky work visible at
preflight time instead of discovering it after a model chooses the operation.

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

- `Jidoka.Runtime.AgentSnapshot.schema_version() == 1`;
- serialized snapshots use the opaque prefix `jidoka:snapshot:v1:`;
- `Jidoka.Harness.Session.schema_version() == 1`;
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
- AgentServer routes `"jidoka.turn.run"` to `Jidoka.Runtime.Actions.RunTurn`,
  which runs the Jidoka harness and writes `:status`, `:last_answer`, and
  a typed `Jidoka.Runtime.AgentServerState` under `agent.state[:jidoka]`.

Jidoka does not delegate the core loop to `Jido.AI.ReAct`. The ReAct-style loop
is implemented through Jidoka's Runic/effect/harness spine.
