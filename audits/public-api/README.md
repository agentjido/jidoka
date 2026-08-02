# Jidoka Public API Audit

Date: 2026-08-02

Status: Review artifact. This document does not define a compatibility
contract.

## Audit Question

Can a developer who is new to Jidoka build, test, and operate an agent through
one clear public path without learning Jidoka runtime internals?

The short answer is: the first agent path is good, but the public surface does
not yet show that simplicity.

A new developer needs only a small set of modules for the normal path:

- `Jidoka`;
- `Jidoka.Agent`;
- `Jidoka.Action`;
- `Jidoka.Context` when the application supplies request data;
- `Jidoka.Control` when the application needs custom policy;
- `Jidoka.Session` when the application needs durable conversation state;
- `Jidoka.Workflow` when the application needs deterministic composed work.

The generated module reference currently shows 150 visible Jidoka modules.
The application contains 329 compiled modules. The difference between the
small learning path and the large module reference is the main public API
problem.

## Evidence Summary

| Measure | Current result |
| --- | ---: |
| Compiled Jidoka modules | 329 |
| Visible module pages | 150 |
| Hidden module pages | 179 |
| Functions on the root `Jidoka` facade | 32 |
| Markdown guides | 45 |
| Lines in Markdown guides | 15,255 |
| Complete example applications | 5 |
| Xref dependency cycles | 0 |

The large codebase does not require a large beginner API. Most of the size is
implementation, contracts, integrations, and advanced operating features.
The documentation must make this distinction stronger.

## What Works Well

### One Package And One Main Facade

The package gives the developer one dependency. The `Jidoka` module has short
verbs for the main use cases. A developer can build and run the first agent
without selecting Jido ecosystem packages.

### Small Agent Definition

The smallest useful agent has one module, one `agent` block, one model, and one
instruction. The DSL compiles to typed data and does not make the developer
construct runtime processes.

### Good Inspection Before A Live Call

`Jidoka.preflight/3` is a strong beginner feature. It shows the prompt and
operation list without a provider call. `Jidoka.inspect/2` gives a readable
view of the compiled agent and plan.

### One Tool Declaration Shape

The `tools` block gives one authoring area for actions, browser tools, MCP
tools, skills, workflows, subagents, and handoffs. A developer can start with
an action and add other sources later.

### Advanced Features Reuse The Main Run Path

Sessions, streaming, review, resume, and process hosting use the same agent and
turn model. The developer does not need to replace the first agent when the
application becomes more capable.

### Examples Have A Clear Difficulty Order

The five examples form a useful progression:

1. Getting Started;
2. Support Agent;
3. Warranty Claim;
4. Durable Refund;
5. Workflow Composition.

## Main Findings

### P0: Generated Documentation Does Not Pass Its Warning Gate

`mix docs --warnings-as-errors` reports references to hidden modules. The
warnings name these internal modules:

- `Jidoka.Agent.RuntimeOptions`;
- `Jidoka.Workflow.Resolver`;
- `Jidoka.Snapshot.Codec`;
- `Jidoka.Chat.Async`;
- `Jidoka.Workflow.Graph`.

The `Jidoka.Chat.Request` module documentation also links to the hidden
`Jidoka.Chat.Async` module.

The architecture guide should be able to name internal owners without making
ExDoc resolve them as public links. Use plain text, escaped names, or an ExDoc
configuration that does not treat those names as links.

### P0: Configuration Text Gives Two Different Dotenv Impressions

The README and Getting Started guide state that ReqLLM loads `.env` by
default. The Configuration guide contains a concept named “No dotenv loading”
and says the package does not load `.env`, but a later section correctly says
that ReqLLM does load it.

The technical distinction is valid: Jidoka does not implement dotenv loading,
but its required ReqLLM dependency does it at application start. A new
developer sees the total application behavior, so all start documents must use
one statement:

> Jidoka does not implement dotenv loading. ReqLLM loads `.env` by default.
> Disable it with `config :req_llm, load_dotenv: false` when the host owns
> credentials.

### P1: The Module Reference Mixes Public API And Implementation

The module groups expose 12 `Jidoka.Adapter.*` modules, nine
`Jidoka.Runtime.*` modules, three `Jidoka.*.Execution` modules, and
`Jidoka.Harness`. The architecture guide identifies these areas as internal or
implementation modules.

Publishing implementation documentation can help maintainers, but placing it
beside application modules makes the supported surface difficult to read. A
new developer cannot know whether `Jidoka.turn/3`,
`Jidoka.Turn.Execution.run/3`, or `Jidoka.Runtime.TurnRunner.run/4` is the
correct entry point.

Recommendation:

- publish the application API and stable extension contracts in normal module
  groups;
- hide implementation modules from the main module index;
- keep maintainer documentation in the architecture guides and source;
- do not use “documented” as a synonym for “supported public API.”

### P1: Application Guides Require Modules Named Runtime Or Adapter

Some normal application guides require implementation namespaces:

- custom operation controls use
  `Jidoka.Runtime.Controls.OperationContext`;
- deterministic tests use `Jidoka.Runtime.LocalOperations`;
- examples and Livebooks build action capabilities with
  `Jidoka.Adapter.Jido.Actions`;
- low-level provider guidance uses `Jidoka.Adapter.ReqLLM` directly.

This creates an architectural choice. These modules are either stable
extension APIs, or their public jobs need owners outside the `Runtime` and
`Adapter` namespaces.

Recommended target seams:

| Current public need | Recommended owner |
| --- | --- |
| Operation control input | `Jidoka.Control.OperationContext` or another public control contract |
| Local operation test handlers | `Jidoka.Test` or a public operation helper |
| Action capability construction | `Jidoka.Action` or automatic agent tool resolution |
| Capability types for extension authors | A public port or capability contract namespace |
| Provider implementation details | Integration guide and internal adapter modules |

### P1: Two Chat Styles Compete For The Beginner Path

The docs show both forms early:

```elixir
MyApp.Assistant.chat("Hello")
Jidoka.chat(MyApp.Assistant, "Hello")
```

Both forms are useful. The problem is that the docs do not give them different
roles. The generated agent also exposes `run_turn/2`, while the facade uses
`turn/3`.

Recommendation:

- make `Jidoka.chat/3` and `Jidoka.turn/3` the canonical documentation path;
- describe `MyApp.Agent.chat/2` and `run_turn/2` once as generated
  convenience functions;
- use one style in all beginner examples;
- keep agent-local calls for code that benefits from the shorter bound-agent
  form.

### P1: The Root Facade Is Flat

The 32 functions on `Jidoka` cover clear jobs, but ExDoc presents a large flat
list. The facade should stay one module. Its documentation can show stronger
groups:

| Group | Functions |
| --- | --- |
| Build | `agent`, `agent!`, `plan`, `plan!`, `import`, `export` |
| Run | `chat`, `turn`, `resume` |
| Async | `chat_async`, `stream`, `await`, `cancel` |
| Session | `session`, `fork_session`, `recover_session` |
| Review | `pending_reviews`, `approve`, `deny` |
| Process host | `start_agent`, `whereis`, `await_agent`, `stop_agent` |
| Inspect | `preflight`, `inspect`, `project` |
| Handoff | `handoff`, `reset_handoff` |
| Error | `normalize_error`, `format_error`, `error_to_map` |

Use ExDoc function groups if the current ExDoc version supports them. This
keeps the “one facade” goal and makes its jobs visible.

### P1: Deterministic Testing Starts Too Low In The Stack

The first provider-free test requires a three-argument LLM capability. A tool
test also uses `Jidoka.Effect.Journal` state and
`Jidoka.Runtime.LocalOperations`. These are valuable extension contracts, but
they are too much for the first agent test.

Recommendation: add a small supported testing surface. It should let a
developer declare a fixed answer or an ordered model/tool script without
learning effect intents, journals, or runtime capabilities. Keep the current
capability functions as the advanced path.

One possible shape is:

```elixir
llm = Jidoka.Test.LLM.sequence([
  operation("local_time", %{city: "Chicago"}),
  final("It is 09:30 in Chicago.")
])

operations = Jidoka.Test.Operations.new(
  local_time: fn args -> {:ok, %{city: args.city, time: "09:30"}} end
)
```

This code is a proposal, not a current API.

### P2: Tool Authoring Has Three Terms In The First Example

The developer sees “tool,” “action,” and “operation” during the first tool
example. The architecture has a good distinction:

- tool: what the developer declares in the agent DSL;
- action: one implementation type for a tool;
- operation: the normalized runtime contract shown to the model.

The Getting Started guide should state this distinction before its first tool.
The module reference for `Jidoka.Action` should also document its supported
options, its `run/2` callback, parameter normalization, context shape, and
return values. At present, the module page is much smaller than its public job.

### P2: Session Chat Has A Target-Dependent Result Shape

`Jidoka.chat/3` returns `{:ok, text}` for an agent and
`{:ok, session, text}` for a caller-managed session. This is a practical API,
but the difference is easy to miss.

Recommendation: keep the behavior, but place a “result shapes” table beside
the first session example. State that the caller must retain the returned
session when no store owns it.

### P2: Some Public Module Pages Have No Public Functions

Some visible modules are contracts, struct pages, generated action modules, or
namespace landing pages. That can be correct. Other pages are visible but do
not help an application developer, for example a public module with only a
hidden internal function.

Review these cases one by one. A module should be visible because it defines a
public type, callback, struct, macro, or useful function. It should not be
visible only because it has a module description.

## Recommended Public Contract Tiers

### Tier 1: Application API

This is the API shown first. It includes the root facade, agent and workflow
authoring, action and control authoring, context, sessions, streaming, and
feature facades.

Compatibility promise: strong.

### Tier 2: Extension Contracts

This includes typed agent, turn, effect, review, memory, session, workflow,
event, trace, store, and operation-source contracts. Developers use it when
they build integrations or stores.

Compatibility promise: documented and versioned, but more detailed than Tier
1.

### Tier 3: Implementation

This includes adapters, runtime orchestration, execution owners, projections,
code generation, and compatibility implementation.

Compatibility promise: none for application code. These modules should not
appear as normal application choices.

### Tier 4: Development And Test

This includes Kino and the proposed high-level testing support. The code can
be public for its environment without entering production runtime builds.

## Recommended Work Order

1. Fix the documentation warning gate and conflicting configuration text.
2. Add explicit public contract tiers to ExDoc and the architecture tests.
3. Group the root facade functions by job.
4. Choose one canonical chat style for beginner documentation.
5. Move or rename the public jobs that currently require `Runtime` or
   `Adapter` modules.
6. Add a high-level deterministic test API.
7. Expand the `Jidoka.Action` module contract documentation.
8. Review every visible namespace with the surface matrix.

## Review Decisions

The maintainer should make these decisions before implementation:

1. Is the root `Jidoka` facade the only recommended application entry point,
   with generated agent functions treated as shortcuts?
2. Are any `Jidoka.Adapter.*` modules supported extension APIs?
3. Should operation-control context move out of `Jidoka.Runtime.*`?
4. Should provider-free test helpers compile only in test, or should they be
   available in production for simulations and evals?
5. Are the low-level turn, effect, session, and workflow structs stable public
   contracts, or are some only inspection data?
6. Should maintainer modules be removed from the normal HexDocs module index?

## Related Artifacts

- [Documentation Alignment Plan](documentation-alignment-plan.md)
- [New Developer Journey](new-developer-journey.md)
- [Module Surface](module-surface.md)
- [Architecture Boundaries](../../guides/architecture-boundaries.md)

## Reproduction Commands

```bash
mix compile --warnings-as-errors
mix docs --warnings-as-errors
mix doctor --full --failed
mix run -e '# enumerate :jidoka application modules with Code.fetch_docs/1'
```

The module count in this audit comes from the compiled `:jidoka` application.
A visible module has a non-hidden module document in `Code.fetch_docs/1`.
