# Import (JSON/YAML)

Use JSON or YAML when agents are authored outside Elixir. Jidoka imports the
document into the same `Jidoka.Agent.Spec` the DSL produces. Executable values
(action modules, control modules, Zoi schemas, Ash resources) resolve only
through caller-supplied registries, so imports never call `String.to_atom/1` on
untrusted input.

## When To Use This

- Use this guide when agents are authored outside Elixir (admin UI, config
  bundle, content repo).
- Use this guide when shipping agents as portable JSON/YAML that operations
  teams can edit.
- Do not use this guide when modules are in your code anyway; the DSL is
  shorter and gives you compile-time validation.
- Do not use this guide for arbitrary user-uploaded YAML without a trust
  story; the import boundary requires deliberate registries.

## Prerequisites

- A working Jidoka project (see [Getting Started](getting-started.md)).
- Familiarity with the operation contract from
  [Tools And Operations](tools-and-operations.md).
- For YAML: the `:yaml_elixir` dependency is already brought in by Jidoka.
- A provider key in scope for the live `chat/3` example. Tests can inject a
  fake LLM instead.

```bash
mix deps.get
mix test
```

## Quick Example

The smallest portable agent is one YAML document plus an `actions` registry.

```elixir
defmodule MyApp.Tools.LocalTime do
  use Jidoka.Action,
    name: "local_time",
    description: "Returns the local time.",
    schema: Zoi.object(%{city: Zoi.string() |> Zoi.default("Chicago")})

  @impl true
  def run(_params, _context), do: {:ok, %{city: "Chicago", time: "09:30"}}
end

yaml = """
version: 1
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
    actions: %{"local_time" => MyApp.Tools.LocalTime}
  )

{:ok, answer} = Jidoka.chat(spec, "What time is it in Chicago?")
answer
```

The same `spec` value comes back regardless of whether the agent was
authored in Elixir, JSON, or YAML.

## Concepts

The import surface is three layers and one trust boundary.

1. **`Jidoka.Import.AgentDocument`** is the on-the-wire shape, validated by
   a Zoi schema. The document has a `version` (currently `1`), an `agent`
   block, and optional `tools`, `controls`, `operations`, `runtime_defaults`,
   and `metadata` blocks.
2. **`Jidoka.Import`** is the public compiler. It accepts a JSON or YAML
   string (or a decoded map), normalizes the document, resolves every
   non-data reference through caller-supplied registries, and produces a
   `Jidoka.Agent.Spec`.
3. **Registries** are plain maps or keyword lists keyed by name. Five
   registries are supported: `actions`, `ash_resources`, `controls`,
   `context_schemas`, `result_schemas`. The trust boundary is here: only
   refs the caller put in the registry can become live modules or schemas.

```diagram
╭───────────────────╮     ╭──────────────────────╮     ╭─────────────────╮
│ JSON / YAML       │────▶│ Jidoka.Import.import │────▶│ AgentDocument   │
│ (string or map)   │     │   (format detected)  │     │ (Zoi validated) │
╰───────────────────╯     ╰──────────┬───────────╯     ╰────────┬────────╯
                                     │                          │
                                     ▼                          ▼
                          ╭──────────────────────╮     ╭─────────────────╮
                          │ Registries           │────▶│ Spec attrs      │
                          │ - actions            │     │ - operations    │
                          │ - ash_resources      │     │ - controls      │
                          │ - controls           │     │ - context_schema│
                          │ - context_schemas    │     │ - result        │
                          │ - result_schemas     │     │ - memory etc.   │
                          ╰──────────────────────╯     ╰────────┬────────╯
                                                                │
                                                                ▼
                                                     ╭──────────────────╮
                                                     │ Jidoka.Agent.Spec│
                                                     │ (same as DSL)    │
                                                     ╰──────────────────╯
```

### Versioning

Every document carries `version: 1`. The schema validates the version and
returns `{:error, {:unsupported_import_document_version, ...}}` for
anything else. Treat the version as the only authoring contract guarantee;
new fields must be opt-in.

### DSL/Import Parity

The DSL and the importer compile to the same `Jidoka.Agent.Spec` shape and
the same `Jidoka.Agent.Spec.Operation` entries. Golden DSL-to-spec tests catch
authoring drift early. When you add a feature to the DSL, add a matching key to
the document schema. When you add a key to the document, add a matching DSL
clause.

### Trust Boundary

Imports never:

- call `String.to_atom/1` or `Module.concat/1` on input;
- load Elixir files from a path supplied by the document;
- assume a default registry; missing refs are an error.

Imports always:

- accept atoms or strings interchangeably in registry keys;
- resolve action modules, control modules, Ash resources, context schemas,
  and result schemas through the registries you pass;
- return `Jidoka.Error.Invalid` on any unknown ref so failures are typed.

## How To

### Step 1: Pick A Format

`Jidoka.import/2` detects JSON when the string starts with `{` or `[`, and
otherwise treats it as YAML. Force a format with `format: :json` or
`format: :yaml` when the heuristic is wrong.

```elixir
{:ok, spec} = Jidoka.import(json_string, format: :json, actions: actions)
{:ok, spec} = Jidoka.import(yaml_string, format: :yaml, actions: actions)
```

### Step 2: Write The Document

The minimal document defines an `agent` block. Anything else is optional.

```yaml
version: 1
agent:
  id: support_agent
  model: openai:gpt-4o-mini
  instructions: Answer support questions tersely.
  context:
    ref: support_context
  result:
    ref: support_result
    max_repairs: 1
  memory:
    scope: session
    capture: conversation
    max_entries: 8
tools:
  actions:
    - local_time
  ash_resources:
    - ref: account_resource
      actions:
        - read_account
  browsers:
    - name: docs
      mode: read_only
      allow:
        - docs.example.com
controls:
  max_turns: 8
  timeout: 30000
  inputs:
    - control: no_secrets
  operations:
    - control: require_approval
      when:
        kind: action
        name: local_time
  outputs:
    - control: safe_reply
```

Key shapes match the DSL: `tools.actions` is a list of action refs;
`controls.operations[].when` is the same match map operation controls
accept in the DSL.

### Step 3: Build The Registries

Each registry is a map (or keyword list) keyed by name. Values are real
Elixir modules or Zoi schemas the caller already trusts.

```elixir
registries = %{
  actions: %{"local_time" => MyApp.Tools.LocalTime},
  ash_resources: %{"account_resource" => MyApp.Accounts.User},
  controls: %{
    "no_secrets" => MyApp.NoSecrets,
    "require_approval" => MyApp.RequireApproval,
    "safe_reply" => MyApp.SafeReply
  },
  context_schemas: %{"support_context" => Zoi.object(%{tenant_id: Zoi.string()})},
  result_schemas: %{"support_result" => Zoi.object(%{answer: Zoi.string()})}
}

{:ok, spec} = Jidoka.import(yaml, registries: registries)
```

`Jidoka.Import` also accepts the registries as top-level options:
`actions:`, `ash_resources:`, `controls:`, `context_schemas:`,
`result_schemas:`. The forms are equivalent; pick one per project.

### Step 4: Handle Missing Refs

A missing ref returns a typed validation error. Match on it explicitly
when you accept user-authored documents.

```elixir
case Jidoka.import(yaml, actions: %{}) do
  {:ok, spec} ->
    {:ok, spec}

  {:error, %Jidoka.Error.Invalid{} = error} ->
    %{details: %{reason: reason}} = Jidoka.error_to_map(error)
    {:error, reason}
end
```

For the YAML above, that surfaces as
`{:unknown_registry_ref, :actions, "local_time"}` when the action registry
is empty.

### Step 5: Use The Imported Spec Like Any Other

The result is `Jidoka.Agent.Spec`. Plan it, preflight it, run it, host it
under Jido - everything that works for a DSL agent works here.

```elixir
{:ok, plan} = Jidoka.plan(spec)
{:ok, preflight} = Jidoka.preflight(spec, "ping")

{:ok, answer} = Jidoka.chat(spec, "ping")
```

### Step 6: Round-Trip With Inspect/Project

To compare authoring paths, lower both to inspection data:

```elixir
imported = Jidoka.inspect(spec)
dsl = Jidoka.inspect(MyApp.SupportAgent)

imported.spec.operations == dsl.spec.operations
#=> true (when the document and DSL declare the same tools)
```

This is exactly how the golden tests assert DSL/import parity.

## Common Patterns

- **Treat documents as data.** Keep YAML alongside the application code,
  load it at boot, and pass the registries from a single trusted module.
- **Use one registry map per environment.** Production registries can
  include modules dev does not; the documents stay the same.
- **Lean on the version field.** Pin `version: 1`; reject anything else
  rather than silently accepting unknown shapes.
- **Compose with `metadata`.** The document's free-form `metadata` block
  flows through to `Spec.metadata` and is visible from
  `Jidoka.inspect/1` - useful for owner tagging and feature flags.
- **Prefer atom and string interchangeability in registries.**
  the import registry matches `:foo` against `"foo"` either direction
  so you can use whichever feels natural per environment.

## Testing

A good import test exercises three behaviors: parsing, ref resolution, and
parity with the equivalent DSL.

```elixir
defmodule MyApp.ImportTest do
  use ExUnit.Case, async: true

  @yaml """
  version: 1
  agent:
    id: time_agent
    model: openai:gpt-4o-mini
    instructions: Call local_time when asked for the time.
  tools:
    actions:
      - local_time
  """

  test "compiles a YAML document into a usable spec" do
    {:ok, spec} =
      Jidoka.import(@yaml,
        actions: %{"local_time" => MyApp.Tools.LocalTime}
      )

    assert spec.id == "time_agent"
    assert [%Jidoka.Agent.Spec.Operation{name: "local_time"}] = spec.operations

    llm = fn _intent, journal, _ctx ->
      case map_size(journal.results) do
        0 -> {:ok, %{type: :operation, name: "local_time", arguments: %{}}}
        _ -> {:ok, %{type: :final, content: "09:30"}}
      end
    end

    assert {:ok, "09:30"} = Jidoka.chat(spec, "now?", llm: llm)
  end

  test "missing action ref returns a typed validation error" do
    assert {:error, %Jidoka.Error.Invalid{} = error} =
             Jidoka.import(@yaml, actions: %{})

    assert %{details: %{reason: {:unknown_registry_ref, :actions, "local_time"}}} =
             Jidoka.error_to_map(error)
  end

  test "DSL and import compile to the same operations" do
    {:ok, spec} =
      Jidoka.import(@yaml,
        actions: %{"local_time" => MyApp.Tools.LocalTime}
      )

    dsl_operations = MyApp.TimeAgent.spec().operations
    assert Enum.map(spec.operations, & &1.name) ==
             Enum.map(dsl_operations, & &1.name)
  end
end
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, %Jidoka.Error.Invalid{}}` with reason `{:unknown_registry_ref, ...}` | A ref in the document was not in the matching registry. | Add the ref or remove it from the document; ref keys are case sensitive. |
| `{:error, {:unsupported_import_document_version, ...}}` | The document version is not `1`. | Bump or downgrade the document to match. |
| `{:error, {:unsupported_import_format, _}}` | `format:` was set to something other than `:json` or `:yaml`. | Pass `:json` or `:yaml`, or remove the option to use detection. |
| JSON decodes but `agent` is missing | The document was top-level keys without an `agent:` block. | `Jidoka.Import` normalizes well-known top-level agent keys, but unfamiliar ones are dropped. Wrap them in `agent:`. |
| Control fires for the wrong operation | The `when:` clause used a key that is not in the operation metadata. | Inspect with `Jidoka.inspect(spec).spec.operations` to confirm metadata keys; the DSL and importer use the same keys. |

## Reference

- [`Jidoka`](`Jidoka`) - public facade: `Jidoka.import/2`.
- [`Jidoka.Import`](`Jidoka.Import`) - compiler and registry option
  handling: `import/2`, `import!/2`, `load/2`, `load!/2`.
- [`Jidoka.Import.AgentDocument`](`Jidoka.Import.AgentDocument`) - the
  validated document schema and version constant.
- Import registry - registry fetch
  semantics used to resolve refs.
- [`Jidoka.Agent.Spec`](`Jidoka.Agent.Spec`) - the spec shape both DSL and
  import compile into.
- [`Jidoka.Agent.Spec.Operation`](`Jidoka.Agent.Spec.Operation`) - the
  operation shape used for both authoring paths.

## Related Guides

- [Agent DSL](agent-dsl.md) - the Elixir-native authoring path and its
  parity with the importer.
- [Tools And Operations](tools-and-operations.md) - operation contract
  documents map to.
- [Inspection And Preflight](inspection-and-preflight.md) - comparing
  imported and DSL specs through inspection.
- [Testing And Evals](testing-and-evals.md) - using imported specs in
  deterministic eval cases.
