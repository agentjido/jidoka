# Projection Internals

`Jidoka.Projection` is the internal dispatcher behind `Jidoka.project/1`. It
converts Jidoka contracts into stable, compact Elixir data.

The dispatcher does not own domain rules. Each architecture area owns one
projector:

```text
Jidoka.Projection
├── AgentSpec       agent definition and controls
├── Agent           agent state, messages, and handoffs
├── Turn            plans, requests, states, cursors, and results
├── Effect          intents, results, and journals
├── Memory          memory requests and results
├── Session         snapshots, sessions, and replay
├── Review          interrupts, requests, and responses
├── Workflow        workflow specs and steps
└── Observability   debug, trace, eval, and event data
```

Jidoka.Portable handles safe recursive values. It converts exceptions,
foreign structs, content parts, and model references into portable data. It
also removes sensitive values from keys that look like credentials.

## When To Use This Guide

Use this guide when you:

- add a new data contract that must support `Jidoka.project/1`;
- change a projected field;
- add an inspection or UI view;
- change redaction or portable-value rules.

Application developers normally use `Jidoka.project/1` and
`Jidoka.inspect/2`. They do not call domain projector modules.

## Projection Flow

```text
Jidoka.project(value)
        │
        ▼
Jidoka.Projection.project(value)
        │
        ├── known contract ──> matching domain projector
        │
        └── other value ─────> Jidoka.Portable.project(value)
```

This direction is important. Projection modules read core contracts. Core
contracts do not call projection modules.

## Add A Projection

### 1. Select The Owner

Put the clause in the projector for the contract area. For example, put a new
effect struct in Jidoka.Projection.Effect.

```elixir
def project(%Effect.Example{} = value) do
  %{
    id: value.id,
    payload: Jidoka.Portable.project(value.payload)
  }
end
```

Do not put the full map in the root dispatcher.

### 2. Add One Dispatch Clause

Add a small clause to `Jidoka.Projection`:

```elixir
def project(%Effect.Example{} = value),
  do: Projection.Effect.project(value)
```

The root dispatcher must stay easy to scan.

### 3. Keep Output Stable

Projection output must contain plain data:

- maps;
- lists;
- strings;
- atoms;
- numbers;
- booleans;
- `nil`.

Do not expose provider clients, processes, functions, Zoi schema internals, or
full third-party structs.

### 4. Use Portable Values

Use Jidoka.Portable.project/1 for nested values that do not have their own
domain projector.

Use a domain projector for known Jidoka contracts. For example,
Jidoka.Projection.Turn calls Jidoka.Projection.Effect for the journal. It
does not send the journal through the generic fallback.

### 5. Test The Contract

Run these tests:

```bash
mix test test/jidoka/projection_test.exs
mix test test/jidoka/inspection_test.exs
mix test test/jidoka/golden/
mix test test/architecture/boundaries_test.exs
```

Add an exact assertion for any new stable output. If a change is intentional,
update the related golden data in the same change.

## Projection And Inspection

`Jidoka.project/1` returns a machine-readable value.

`Jidoka.inspect/2` builds a human-readable view. Inspection can add a `:kind`,
a timeline, a graph, or diagnostics. Inspection should compose projectors. It
must not copy all contract mapping rules.

Example:

```elixir
spec = Jidoka.agent!(id: "demo", model: %{provider: :test, id: "m"})

Jidoka.project(spec)
#=> %{id: "demo", model: "test:m", ...}

Jidoka.inspect(spec)
#=> %{kind: :agent, spec: %{...}, plan: %{...}}
```

## Redaction

Jidoka.Portable redacts values when a key contains a sensitive word such as
`authorization`, `credential`, `password`, `secret`, or `token`.

Do not depend on redaction as the only security control. Do not place secrets
in agent specs, turn state, snapshots, events, or metadata.

## Boundary Rules

- Core contract modules must not depend on `Jidoka.Projection.*`.
- Runtime modules must call a specific projector when they need event data.
- The root dispatcher must contain dispatch only.
- A projector can depend on contracts and Jidoka.Portable.
- A projector must not call the root `Jidoka` facade.
- Projection changes require tests because projections are public data.

See [Architecture Boundaries](architecture-boundaries.md) for the full layer
map.
