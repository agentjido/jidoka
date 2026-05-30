# Runtime And Harness

Jidoka V2 separates authoring, executable data, and effect execution.

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
- delegation to `Jidoka.Runtime.TurnRunner`.

The harness is intentionally thin. Future session queues, stores, replay,
approval flows, and eval fixtures belong here rather than in the root `Jidoka`
module.

## Turn Runner

`Jidoka.Runtime.TurnRunner` owns the loop:

1. run input controls;
2. run the Runic prompt/effect planning workflow;
3. optionally hibernate at a safe checkpoint;
4. interpret pending effects;
5. apply effect results to turn state;
6. loop until final answer or max model turns;
7. run result controls before returning.

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

## Durability

Jidoka snapshots semantic state:

```elixir
{:hibernate, snapshot} =
  Jidoka.run_turn(spec, "Hello",
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

## Jido Relationship

Jidoka uses Jido as the foundation:

- DSL agent modules are also `Jido.Agent` modules;
- tools are Jido actions;
- action schemas and execution stay on the Jido side.
- `Jidoka.Jido` is the default Jido runtime instance started by
  `Jidoka.Application`.
- `MyAgent.start/1` and `Jidoka.start_agent/2` start DSL agents under
  `Jido.AgentServer`.
- AgentServer routes `"jidoka.turn.run"` to `Jidoka.Runtime.Actions.RunTurn`,
  which runs the Jidoka harness and writes `:status`, `:last_answer`, and
  a typed `Jidoka.Runtime.AgentServerState` under `agent.state[:jidoka]`.

Jidoka does not delegate the core loop to `Jido.AI.ReAct`. The ReAct-style loop
is implemented through Jidoka's Runic/effect/harness spine.
