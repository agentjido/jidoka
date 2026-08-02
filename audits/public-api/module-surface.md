# Public Module Surface

Date: 2026-08-02

This artifact classifies the 150 modules that currently have a visible module
page. It uses namespace-level rows so all visible modules are accounted for
without treating every struct as a separate product decision.

## Target Tiers

| Tier | Meaning |
| --- | --- |
| Primary | Normal application and agent-authoring API. Show this first. |
| Feature | Public API for an optional product capability. |
| Contract | Stable typed contract or extension behavior for advanced users. |
| Internal | Implementation detail. Hide it from the normal module index. |
| Development | Public only in development or test environments. |
| Mixed | The namespace contains modules from more than one target tier. Split its documentation treatment. |

## Complete Namespace Matrix

The visible-page counts in this table total 150.

| Current namespace | Visible pages | Target tier | Review |
| --- | ---: | --- | --- |
| `Jidoka` | 1 | Primary | Keep as the canonical application facade. Group its 32 functions by job. |
| `Jidoka.Action` | 1 | Primary | Expand the module contract for action options, `run/2`, input normalization, context, and results. |
| `Jidoka.Adapter.*` | 12 | Internal | Remove from the normal application module index. Keep source and maintainer documentation. |
| `Jidoka.Agent.*` | 12 | Mixed | `Jidoka.Agent` is Primary. Message, state, spec, and spec children are Contract. |
| `Jidoka.AgentView` | 1 | Feature | Keep for UI view-state applications. Do not place it before basic chat and stream APIs. |
| `Jidoka.ApprovalPredicate` | 1 | Feature | Keep as the stable dynamic approval behavior. |
| `Jidoka.Browser` | 1 | Feature | Keep as the public browser tool-source facade. Hide its Jido action implementation modules. |
| `Jidoka.Cancellation` | 1 | Contract | Keep as the typed result of public cancellation calls. |
| `Jidoka.Chat.*` | 1 | Feature | `Jidoka.Chat.Request` is the public async handle. Keep task ownership modules hidden. |
| `Jidoka.Config` | 1 | Feature | Keep as the public application-default API. Remove conflicting dotenv wording. |
| `Jidoka.ContentPart` | 1 | Contract | Keep as the provider-neutral multimodal input contract. |
| `Jidoka.Context` | 1 | Primary | Keep as the public request, control, and action context API. |
| `Jidoka.Control` | 1 | Primary | Keep as the custom policy authoring behavior. |
| `Jidoka.Controls.*` | 3 | Feature | Keep the built-in controls visible beside `Jidoka.Control`. |
| `Jidoka.Debug.*` | 3 | Feature | Keep the root debug facade. Treat returned diagnostics and summary structs as Contract. |
| `Jidoka.Effect.*` | 6 | Contract | Keep for extension authors, replay, and deterministic low-level tests. Do not teach it in the first test. |
| `Jidoka.Error.*` | 8 | Contract | Keep error types that callers can receive or match. Keep formatting and normalization implementation hidden. |
| `Jidoka.Eval.*` | 3 | Feature | Keep as the public deterministic evaluation API. Add a higher-level test helper beside it. |
| `Jidoka.Event` | 1 | Contract | Keep as the public stream and trace event contract. |
| `Jidoka.Export` | 1 | Feature | Keep for direct advanced use, but teach `Jidoka.export/2` first. |
| `Jidoka.Handoff.*` | 3 | Mixed | Handoff behavior is Feature. Owner-store behavior and implementation are Contract. |
| `Jidoka.Harness` | 1 | Internal | Compatibility implementation. Remove it from normal application choices. |
| `Jidoka.Id` | 1 | Contract | Keep only if custom stores and deterministic tests are expected to inject or generate Jidoka ids. |
| `Jidoka.Import.*` | 2 | Feature | Keep import and agent-document contracts, but teach `Jidoka.import/2` first. |
| `Jidoka.Inspection.*` | 2 | Feature | Keep preflight result data. Teach `Jidoka.preflight/3` and `Jidoka.inspect/2` first. |
| `Jidoka.Instructions` | 1 | Feature | Keep because it defines the dynamic instruction provider behavior. Add a visible callback-oriented example. |
| `Jidoka.Jido` | 1 | Feature | Keep as the advanced process-hosting integration facade. Do not mix its internals with direct chat. |
| `Jidoka.Kino` | 1 | Development | Keep visible only in development and test builds. |
| `Jidoka.Memory.*` | 9 | Mixed | `Jidoka.Memory` is Feature. Entry, request, result, and store modules are Contract. |
| `Jidoka.ModelPolicy` | 1 | Feature | Keep as the public routing, retry, and fallback contract. |
| `Jidoka.Operation.*` | 9 | Contract | Keep source and capability behaviors for extension authors. Consider a public local-operation helper outside Runtime. |
| `Jidoka.Projection` | 1 | Internal | Application code should use `Jidoka.project/1`. Keep domain projectors hidden. |
| `Jidoka.Review.*` | 6 | Mixed | Review data is Contract. `Jidoka.Review.Execution` is Internal. Root review verbs are Primary/Feature. |
| `Jidoka.Runtime.*` | 9 | Mixed | Most modules are Internal. Public control input, local test operations, and capability types need new public owners or an explicit extension promise. |
| `Jidoka.Schema` | 1 | Internal | It is a package normalization helper. Application examples should not require it. |
| `Jidoka.Session.*` | 10 | Mixed | `Jidoka.Session` is Primary/Feature. Data, store, lease, lineage, and replay are Contract. Execution is Internal. |
| `Jidoka.Skill` | 1 | Feature | Keep as the public skill facade. Its Jido adapter stays internal. |
| `Jidoka.Snapshot` | 1 | Contract | Keep as the durable pause/resume contract. Its codec stays internal. |
| `Jidoka.Stream` | 1 | Feature | Keep as the public event-stream API. |
| `Jidoka.Trace.*` | 4 | Mixed | Trace is Feature. Policy and sink modules are Contract. |
| `Jidoka.Turn.*` | 7 | Mixed | Plan, request, result, state, cursor, and transition are Contract. Execution is Internal. |
| `Jidoka.Usage` | 1 | Contract | Keep as the public usage result contract. |
| `Jidoka.Workflow.*` | 17 | Mixed | Workflow authoring and operational facades are Feature. Specs, steps, refs, runs, schedules, snapshots, and loop results are Contract. Internal compiler/runtime modules are already hidden. |

## Current Implementation Pages To Review First

### Adapter Pages

The following 12 adapter modules are currently visible:

- `Jidoka.Adapter.Jido.Actions`;
- `Jidoka.Adapter.Jido.AgentServerState`;
- `Jidoka.Adapter.Jido.Browser.Tools.ReadPage`;
- `Jidoka.Adapter.Jido.Browser.Tools.SearchWeb`;
- `Jidoka.Adapter.Jido.Browser.Tools.SnapshotUrl`;
- `Jidoka.Adapter.Jido.RunTurn`;
- `Jidoka.Adapter.Jido.Signals`;
- `Jidoka.Adapter.Jido.Skill`;
- `Jidoka.Adapter.ReqLLM`;
- `Jidoka.Adapter.ReqLLM.Decision`;
- `Jidoka.Adapter.Runic.Background`;
- `Jidoka.Adapter.Runic.TurnCompiler`.

Recommended default: hide these module pages from application developers. If
one adapter has a supported integration job, expose that job through a public
integration facade and document its compatibility promise.

Generated browser action modules and `RunTurn` inherit a large action API from
Jido. Their visible pages make a small Jidoka integration look larger than it
is.

### Runtime Pages

The following nine runtime modules are currently visible:

- `Jidoka.Runtime.Capabilities`;
- `Jidoka.Runtime.Controls`;
- `Jidoka.Runtime.Controls.Operation`;
- `Jidoka.Runtime.Controls.OperationContext`;
- `Jidoka.Runtime.EffectInterpreter`;
- `Jidoka.Runtime.LocalOperations`;
- `Jidoka.Runtime.Review`;
- `Jidoka.Runtime.Spine.Steps`;
- `Jidoka.Runtime.TurnRunner`.

Recommended split:

| Module | Target |
| --- | --- |
| `Runtime.Capabilities` | Move its stable types to a public extension contract, or state that the full module is advanced public API. |
| `Runtime.Controls.OperationContext` | Move the type to the public control namespace. |
| `Runtime.LocalOperations` | Move the helper to a public operation or test namespace. |
| Other runtime modules | Hide from the normal module index. Keep maintainer guides. |

### Execution Pages

These application-service owners are visible:

- `Jidoka.Turn.Execution`;
- `Jidoka.Session.Execution`;
- `Jidoka.Review.Execution`.

The root and domain facades already cover the application use cases. Treat the
execution modules as implementation unless a concrete extension use case
cannot use the facades.

### Other Internal Pages

- `Jidoka.Harness` is a compatibility implementation.
- `Jidoka.Projection` is behind `Jidoka.project/1`.
- `Jidoka.Schema` is a normalization helper used by package code.

These pages add choices but do not add a required application capability.

## Primary API Proposal

Show these modules in the first module group:

- `Jidoka`;
- `Jidoka.Agent`;
- `Jidoka.Action`;
- `Jidoka.Context`;
- `Jidoka.Control`;
- `Jidoka.Session`;
- `Jidoka.Workflow`;
- `Jidoka.Stream`;
- `Jidoka.Config`.

Optional feature facades can follow in a second group:

- `Jidoka.AgentView`;
- `Jidoka.ApprovalPredicate`;
- `Jidoka.Browser`;
- `Jidoka.Debug`;
- `Jidoka.Eval`;
- `Jidoka.Import`;
- `Jidoka.Export`;
- `Jidoka.Instructions`;
- `Jidoka.Jido`;
- `Jidoka.Memory`;
- `Jidoka.ModelPolicy`;
- `Jidoka.Skill`;
- `Jidoka.Trace`;
- `Jidoka.Kino` in development and test only.

All other visible modules should be in a clearly named “Extension Contracts”
group or hidden as implementation.

## Root Facade Surface

The root facade currently has 32 documented functions. They form nine clear
groups.

### Build

- `agent/1`;
- `agent!/1`;
- `plan/1`;
- `plan!/1`;
- `import/2`;
- `export/2`.

### Run

- `chat/3`;
- `turn/3`;
- `resume/2`.

### Async

- `chat_async/3`;
- `stream/2`;
- `await/2`;
- `cancel/2`.

### Session

- `session/2`;
- `session/3`;
- `fork_session/2`;
- `recover_session/2`.

### Review

- `pending_reviews/1`;
- `approve/3`;
- `deny/3`.

### Process Host

- `start_agent/2`;
- `whereis/2`;
- `await_agent/2`;
- `stop_agent/2`.

### Inspect

- `preflight/3`;
- `inspect/2`;
- `project/1`.

### Handoff

- `handoff/1`;
- `reset_handoff/1`.

### Error

- `normalize_error/2`;
- `format_error/1`;
- `error_to_map/1`.

No root function appears unrelated to the package goal. The problem is
presentation, not root-facade responsibility. Keep the facade and group it.

## Public Boundary Rules To Automate

After the maintainer approves the target tiers, add a machine-readable module
manifest and tests for these rules:

1. Every compiled module has one tier.
2. Primary and Feature modules have public module documentation.
3. Contract modules have module documentation, public types, and clear
   extension purpose.
4. Internal modules use `@moduledoc false` and do not appear in normal ExDoc
   groups.
5. Application guides do not tell developers to call Internal modules.
6. Development modules do not compile in production.
7. The root facade delegates to owner modules and stays free of implementation
   algorithms.

This manifest should become the source for ExDoc groups, Doctor exclusions,
and architecture tests. That removes three independent lists that can drift.
