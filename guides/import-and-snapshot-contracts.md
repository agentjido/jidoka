# Import And Snapshot Contracts

Jidoka has three versioned data boundaries: the import document
(`Jidoka.Import.AgentDocument`), the runtime snapshot
(`Jidoka.Runtime.AgentSnapshot`), and the harness session
(`Jidoka.Harness.Session`). Each one declares an explicit `version`/`schema_version`
field, fails fast on unsupported values, and stays portable across releases.
This guide documents those boundaries plus the registry shape that backs
import.

## When To Use This

- Use this guide when you are persisting Jidoka data outside the BEAM (files,
  databases, message queues) and need to plan for forward/backward
  compatibility.
- Use this guide when you build importers, exporters, or serializers that
  cross process or release boundaries.
- Do not use this guide for in-process state handling; for that see
  [Turn And Effect Contracts](turn-and-effect-contracts.md).

## Prerequisites

- You have read [Agent Spec Contract](agent-spec-contract.md) and
  [Turn And Effect Contracts](turn-and-effect-contracts.md).
- You can build and run a Jidoka turn.

## Quick Example

Each contract round-trips through its module's `new/1` (or `serialize`/`deserialize`)
function. Import takes raw YAML/JSON plus a registry; snapshot takes terminal
state plus a cursor; session aggregates the rest.

```elixir
# Import (version 1)
yaml = """
agent:
  id: time_agent
  model: openai:gpt-4o-mini
  instructions: Call local_time when asked for the time.
tools:
  actions:
    - local_time
"""

{:ok, spec} =
  Jidoka.import(yaml,
    actions: %{"local_time" => MyApp.LocalTime}
  )

# Snapshot (schema_version 1, "jidoka:snapshot:v1:" prefix)
{:ok, snapshot} =
  Jidoka.Runtime.AgentSnapshot.from_turn_state(turn_state, Jidoka.Turn.Cursor.after_prompt())

{:ok, serialized} = Jidoka.Runtime.AgentSnapshot.serialize(snapshot)
String.starts_with?(serialized, "jidoka:snapshot:v1:")
#=> true

# Session (schema_version 1)
{:ok, session} = Jidoka.Harness.Session.start(spec)
```

## Concepts

```diagram
╭───────────────────╮       ╭───────────────────╮       ╭───────────────────╮
│ Import.Agent      │       │ Runtime.Agent     │       │ Harness.Session   │
│ Document          │       │ Snapshot          │       │                   │
│  version: 1       │       │  schema_version:1 │       │  schema_version:1 │
╰─────────┬─────────╯       ╰─────────┬─────────╯       ╰─────────┬─────────╯
          │                           │                            │
          ▼                           ▼                            ▼
   Agent.Spec                  Hibernate/Resume               Persisted run
   (compiled)                  ("jidoka:snapshot:v1:")        envelope
```

Each version field is the **compatibility boundary**. Constructors validate
the version on load and return `{:error, {:unsupported_..._version, found, expected}}`
when they do not match.

## Fields

### `Jidoka.Import.AgentDocument`

Portable JSON/YAML authoring document.

| Field | Type | Default | Purpose |
| --- | --- | --- | --- |
| `version` | positive integer | `1` (current) | Document version. `Jidoka.Import.AgentDocument.version/0` returns the supported value. |
| `agent` | map | required | Spec attributes (`id`, `model`, `instructions`, etc.). |
| `tools` | map | `%{}` | Tool registry references (`actions`, `ash_resources`, `browsers`, `mcp_tools`, etc.). |
| `controls` | map | `%{}` | Inline controls config. |
| `operations` | `[map()]` | `[]` | Inline operation definitions. |
| `runtime_defaults` | map | `%{}` | Maps to `Spec.runtime_defaults`. |
| `metadata` | map | `%{}` | Caller metadata. |

`AgentDocument.new/1` enforces `version == 1`; any other value returns
`{:error, {:unsupported_import_document_version, version, 1}}`.

### Import Registries

Imports never call `String.to_atom/1` on input. Module and schema references
in YAML/JSON are resolved through caller-provided registries passed to
`Jidoka.Import.import/2`:

| Option | Resolves | Shape |
| --- | --- | --- |
| `:actions` (or `:registries[:actions]`) | Jido action modules referenced under `tools.actions`. | `%{"local_time" => MyApp.LocalTime}` |
| `:ash_resources` | Ash resources for AshJido sources. | `%{"posts" => MyApp.Posts.Post}` |
| `:controls` | Custom control modules. | `%{"approval" => MyApp.Approvals}` |
| `:context_schemas` | Zoi schemas for `spec.context_schema`. | `%{"chat_context" => MyApp.ChatContext.schema()}` |
| `:result_schemas` | Zoi schemas for `spec.result`. | `%{"answer" => MyApp.Answer.schema()}` |

Use the plural option (`actions: %{...}`) for direct overrides, or pass the
full bag via `registries: [actions: ..., controls: ...]`.

### `Jidoka.Runtime.AgentSnapshot`

Serializable semantic snapshot used for hibernate/resume.

| Field | Type | Default | Purpose |
| --- | --- | --- | --- |
| `schema_version` | positive integer | `1` (current) | Compatibility boundary. `AgentSnapshot.schema_version/0` returns the supported value. |
| `snapshot_id` | non-empty string | generated prefixed UUIDv7 (`"snap_…"`) | Stable id for storage and traces. |
| `agent_id` | non-empty string | required | Mirrors `Spec.id`. |
| `cursor` | `Turn.Cursor.t()` | required | Next safe resume boundary. |
| `turn_state` | `Turn.State.t()` | required | Full turn state at snapshot time. |
| `metadata` | map | `%{}` | Snapshot metadata (pending review data, caller tags, etc.). |

**Serialization format.** `AgentSnapshot.serialize/1` produces an opaque
string with the prefix `"jidoka:snapshot:v1:"` followed by URL-safe Base64.
The prefix is the wire-level version tag. `AgentSnapshot.deserialize/1`
refuses any other prefix with `{:error, :invalid_snapshot_serialization}`.

Snapshots refuse non-portable values (functions, pids, ports, references) and
return `{:error, {:non_serializable_snapshot_value, path, type}}` on
serialization.

### `Jidoka.Harness.Session`

Serializable envelope for running an agent across requests.

| Field | Type | Default | Purpose |
| --- | --- | --- | --- |
| `schema_version` | positive integer | `1` (current) | Compatibility boundary. `Harness.Session.schema_version/0` returns the supported value. |
| `session_id` | non-empty string | generated prefixed UUIDv7 (`"sess_…"`) | Stable session id. |
| `agent_id` | non-empty string | required | Mirrors `Spec.id`. |
| `spec` | `Agent.Spec.t()` | required | The compiled spec the session runs. |
| `status` | `:new \| :running \| :hibernated \| :waiting \| :finished \| :error` | `:new` | Lifecycle marker. |
| `requests` | `[Turn.Request.t()]` | `[]` | Append-only request history. |
| `snapshots` | `[AgentSnapshot.t()]` | `[]` | Append-only snapshot history (latest at the tail). |
| `result` | `Turn.Result.t() \| nil` | `nil` | Last finished result. |
| `pending_reviews` | `[Review.Request.t()]` | `[]` | Outstanding review requests blocking the session. |
| `error` | term or `nil` | `nil` | Last error when `status == :error`. |
| `metadata` | map | `%{}` | Session metadata. |

### What Changes Across Versions

The version fields exist precisely so the implementation can evolve without
breaking persisted data:

| Boundary | What may change between versions | Stability promise |
| --- | --- | --- |
| `AgentDocument` v1 | Tool registry shape, controls vocabulary, operation kinds. | The `version` field is the wire signal. New versions add new constructors; old versions stay loadable until intentionally dropped. |
| `AgentSnapshot` v1 | Internal `Turn.State` fields, cursor metadata, capture of new domain values. | The `"jidoka:snapshot:v1:"` prefix is the wire signal. New schema versions get a new prefix. |
| `Harness.Session` v1 | Status set, snapshot list pruning, review request shape. | The `schema_version` field is the wire signal. |

Loaders **must** reject unsupported versions instead of best-effort guessing.

## Common Patterns

- **Persist `serialize/1` output, not the struct.** The serialized string is
  the durable wire format; the in-memory struct is for convenience.
- **Treat the version field as the contract.** Always check it in any custom
  loader; never strip or rewrite it silently.
- **Keep registries explicit.** Build the action/control/schema registries at
  boot and pass them into `Jidoka.import/2` rather than relying on global
  state.
- **Pair snapshots with cursors.** Snapshots without cursors cannot resume
  safely; the cursor is what defines the next safe phase boundary.

## Testing

Round-trip tests are the cheapest correctness check for these boundaries.

```elixir
test "snapshot round-trips through serialization" do
  {:ok, snapshot} =
    Jidoka.Runtime.AgentSnapshot.from_turn_state(turn_state, Jidoka.Turn.Cursor.after_prompt())

  {:ok, serialized} = Jidoka.Runtime.AgentSnapshot.serialize(snapshot)
  assert String.starts_with?(serialized, "jidoka:snapshot:v1:")

  {:ok, restored} = Jidoka.Runtime.AgentSnapshot.deserialize(serialized)
  assert restored.snapshot_id == snapshot.snapshot_id
  assert restored.schema_version == 1
end

test "rejects an unsupported document version" do
  assert {:error, {:unsupported_import_document_version, 99, 1}} =
           Jidoka.Import.AgentDocument.new(%{version: 99, agent: %{"id" => "x"}})
end
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, {:unsupported_import_document_version, found, expected}}` | YAML/JSON declares a different `version`. | Update the document to the expected version or migrate it before loading. |
| `{:error, :invalid_snapshot_serialization}` | Input did not start with `"jidoka:snapshot:v1:"`. | Confirm the durable blob was produced by `AgentSnapshot.serialize/1`. |
| `{:error, {:non_serializable_snapshot_value, path, type}}` | A function, pid, port, or reference reached `Turn.State`. | Replace runtime values with serializable data before snapshotting. |
| `{:error, {:unsupported_snapshot_schema_version, found, expected}}` | Snapshot map has a non-matching `schema_version`. | Run a migration step before calling `AgentSnapshot.new/1`. |
| `Jidoka.import/2` raises about an unknown action | Registry is missing the referenced module. | Add the action to `actions:` or `registries[:actions]`. |

## Reference

- [`Jidoka.Import.AgentDocument`](`Jidoka.Import.AgentDocument`) - `version/0`,
  `new/1`, `new!/1`.
- [`Jidoka.Import`](`Jidoka.Import`) - `import/2`, registry options.
- [`Jidoka.Runtime.AgentSnapshot`](`Jidoka.Runtime.AgentSnapshot`) -
  `schema_version/0`, `serialize/1`, `deserialize/1`,
  `from_turn_state/3`.
- [`Jidoka.Harness.Session`](`Jidoka.Harness.Session`) - `schema_version/0`,
  `start/2`, `put_request/2`, `put_snapshot/2`, `put_result/2`.
- [`Jidoka.Turn.Cursor`](`Jidoka.Turn.Cursor`) - cursor shape stored on every
  snapshot.
- [`Jidoka.Turn.State`](`Jidoka.Turn.State`) - state shape stored on every
  snapshot.

## Related Guides

- [Agent Spec Contract](agent-spec-contract.md) - the spec compiled by
  imports and embedded in sessions.
- [Turn And Effect Contracts](turn-and-effect-contracts.md) - the state and
  cursor shapes inside a snapshot.
- [Runtime And Harness](runtime-and-harness.md) - how sessions and snapshots
  are produced and resumed.
