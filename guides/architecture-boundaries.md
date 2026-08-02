# Architecture Boundaries

Jidoka is one package with several clear layers. The package gives developers
one dependency and one main entry point. It does not put all responsibilities
in one module.

This structure keeps the easy entry point and protects the Jido integration
boundaries.

## Dependency Direction

Dependencies point inward. A lower layer must not call a higher layer.

```text
Public facades and authoring DSLs
│
├── Turn, session, and review use cases
│   │
│   ├── Runtime orchestration and ports
│   │   │
│   │   └── Core data contracts and pure transitions
│   │
│   └── Adapters for Jido, ReqLLM, and Runic
│       │
│       └── Core contracts and runtime ports
│
└── Inspection and presentation
    │
    └── Core contracts and domain projectors
```

The key rules are:

1. Core contracts do not depend on runtime modules, adapters, projections, or
   the root `Jidoka` facade.
2. Pure turn changes stay in `Jidoka.Turn.Transition` and pure session changes
   stay in `Jidoka.Session.Transitions`.
3. External effects use `Jidoka.Effect.Intent` and
   `Jidoka.Runtime.EffectInterpreter`.
4. All operation families implement `Jidoka.Operation.Source`. The source
   provides the operation data and the matching runtime capability.
5. Adapter modules depend on Jidoka contracts. Core contracts do not depend on
   adapter modules.
6. Projections read contracts. Contracts do not call projection modules.
7. Internal modules do not call the root `Jidoka` facade. They call the owner
   module for the use case.
8. `Jidoka.Kino` compiles only in the `:dev` and `:test` environments.
9. A Zoi-backed struct uses `@schema` as its normalized final data contract.
   Its constructor normalizes untrusted input and finishes through schema
   parsing. Its `t()` type, enforced keys, and struct fields come from that
   schema.
10. Runtime modules receive edge behavior through injected functions or
    capabilities. They do not call adapters or projections.
11. The complete source dependency graph stays free of cycles.

The architecture tests in `test/architecture/boundaries_test.exs` enforce these
rules. The `mix quality` task runs these tests and the full dependency-cycle
check.

## Major Module Map

```text
Jidoka
├── Public facades
│   ├── Jidoka                    main short API
│   ├── Jidoka.Agent              agent DSL and agent facade
│   ├── Jidoka.Session            durable session facade
│   ├── Jidoka.Workflow           workflow DSL and workflow facade
│   ├── Jidoka.Workflow.Background durable workflow facade
│   ├── Jidoka.Action             Jido action authoring facade
│   ├── Jidoka.Control            control authoring facade
│   ├── Jidoka.Browser            browser source facade
│   ├── Jidoka.Skill              skill source facade
│   └── Jidoka.Jido               default Jido process host
│
├── Authoring and normalization
│   ├── Jidoka.Agent.Dsl          Spark agent declarations
│   ├── Jidoka.Agent.ToolSources  tool declaration compiler
│   ├── Jidoka.Workflow.Dsl       Spark workflow declarations
│   ├── Jidoka.Workflow.Resolver  workflow definition resolution
│   ├── Jidoka.Import             JSON and YAML to agent contracts
│   ├── Jidoka.Export             agent contracts to portable data
│   └── Jidoka.Instructions       per-request instruction resolution
│
├── Application composition and use cases
│   ├── Jidoka.Agent.RuntimeOptions runtime dependency composition
│   ├── Jidoka.Turn.Execution     run or resume one turn
│   ├── Jidoka.Session.Execution  create, run, recover, or fork sessions
│   ├── Jidoka.Review.Execution   list, approve, or deny reviews
│   ├── Jidoka.Chat.Async         async request lifecycle
│   ├── Jidoka.Chat.RequestController request process ownership
│   └── Jidoka.Workflow.Scheduler own schedules and trigger runs
│
├── Core contracts and pure changes
│   ├── Jidoka.Agent
│   │   ├── Spec                  immutable agent definition
│   │   ├── State                 durable semantic state
│   │   └── Message               provider-neutral message
│   ├── Jidoka.Turn
│   │   ├── Plan                  compiled turn data
│   │   ├── Request               normalized input
│   │   ├── State                 in-flight state
│   │   ├── Cursor                safe resume boundary
│   │   ├── Result                final result
│   │   └── Transition            pure turn state changes
│   ├── Jidoka.Effect
│   │   ├── Intent                effect description
│   │   ├── Result                effect observation
│   │   └── Journal               replay evidence
│   ├── Jidoka.Session
│   │   ├── Data                  durable session contract
│   │   ├── Transitions           pure lease and state changes
│   │   ├── Store                 persistence port
│   │   ├── Lease                 worker ownership data
│   │   └── Lineage               fork history data
│   ├── Jidoka.Snapshot           durable turn checkpoint
│   ├── Jidoka.Review             interrupt, request, response, and policy
│   ├── Jidoka.Memory             memory contracts and store port
│   ├── Jidoka.Workflow           definition, step, run, and schedule data
│   ├── Jidoka.ContentPart        provider-neutral text and media
│   ├── Jidoka.Context            policy input context
│   ├── Jidoka.Event              runtime event contract
│   ├── Jidoka.Cancellation       cancellation evidence
│   └── Jidoka.Usage              token and cost data
│
├── Ports and application services
│   ├── Jidoka.Operation.Capability operation execution port
│   ├── Jidoka.Operation.Source   operation data and capability seam
│   ├── Jidoka.Session.Store      session persistence port
│   ├── Jidoka.Memory.Store       memory persistence port
│   ├── Jidoka.Trace.Sink         trace output port
│   ├── Jidoka.Handoff.OwnerStore conversation owner port
│   └── Jidoka.ModelPolicy        model routing and fallback policy
│
├── Runtime effect shell
│   ├── Jidoka.Runtime.TurnRunner
│   ├── Jidoka.Runtime.EffectInterpreter
│   ├── Jidoka.Runtime.Capabilities
│   ├── Jidoka.Runtime.Controls
│   ├── Jidoka.Runtime.EventDispatcher
│   ├── Jidoka.Runtime.Spine.Steps
│   ├── Jidoka.Memory.Runtime     recall and capture coordination
│   ├── Jidoka.Workflow.Runtime.* workflow step execution
│   └── Jidoka.Workflow.Loop      bounded loop execution
│
├── External adapters
│   ├── Jidoka.Adapter.Jido
│   │   ├── Actions               Jido action execution
│   │   ├── AgentServer           process-hosted turn facade
│   │   ├── AgentServerState      Jido state translation
│   │   ├── RunTurn               Jido signal action
│   │   ├── Signals               signal construction
│   │   ├── Browser               jido_browser actions
│   │   └── Skill                 jido_ai skills
│   ├── Jidoka.Adapter.ReqLLM     model provider adapter
│   └── Jidoka.Adapter.Runic
│       ├── TurnCompiler          turn workflow compiler
│       ├── OperationBatch        parallel operation execution
│       ├── Workflow              declarative workflow execution
│       ├── Background            Runic runner bridge
│       └── LuaPlan               Lua workflow execution
│
├── Inspection and presentation
│   ├── Jidoka.Projection         public projection dispatcher
│   ├── Jidoka.Projection.*       projectors by architecture area
│   ├── Jidoka.Inspection
│   ├── Jidoka.Debug
│   ├── Jidoka.Session.Replay
│   ├── Jidoka.Workflow.Graph
│   ├── Jidoka.Trace
│   ├── Jidoka.AgentView
│   └── Jidoka.Kino               dev and test only
│
├── Shared support
│   ├── Jidoka.Config             package configuration
│   ├── Jidoka.Schema             common data validation helpers
│   ├── Jidoka.Error              normalized error data
│   ├── Jidoka.Error.*            error types, classes, and formatting
│   ├── Jidoka.Id                 identifier generation boundary
│   ├── Jidoka.Portable           recursive portable-value conversion
│   └── Jidoka.Snapshot.Codec     authenticated snapshot encoding
│
└── Compatibility
    └── Jidoka.Harness            thin delegate for old advanced callers
```

## Module Ownership Lines

The table shows the job of each major module area. It also shows what that area
must not own.

| Module area | Owns | Does not own |
| --- | --- | --- |
| `Jidoka` and public facades | Short developer workflows and stable verbs | Provider protocol details or durable algorithms |
| `Jidoka.Agent.*` and `Jidoka.Workflow.Dsl.*` | Compile-time authoring and normalization | Turn execution or storage |
| Agent runtime options (internal) | Default runtime dependency wiring | Runtime execution or provider translation |
| Workflow resolver (internal) | Workflow module resolution and validation | Runtime execution or adapter translation |
| `Jidoka.*.Execution` | Application workflow coordination | Provider SDK calls or presentation |
| Contract modules | Typed data and validation | Processes, network calls, or storage calls |
| Transition modules | Pure state changes | Clock reads, identifiers, persistence, or adapter calls |
| Port modules | Small behavior contracts for effects and stores | Concrete provider policy |
| `Jidoka.Runtime.*` | Effect planning, capability calls, and turn control | Jido, ReqLLM, or Runic protocol translation |
| `Jidoka.Adapter.*` | Large external framework translations | Public workflow ownership |
| `Jidoka.Operation.Source.*` | Tool-family adapters behind one source behavior | Turn-loop ownership |
| Store and sink implementations | One concrete persistence or output method | Use-case coordination |
| `Jidoka.Projection.*` | Read-only views of contracts | Domain state changes |
| `Jidoka.Kino.*` | Notebook presentation in development and test | Production runtime behavior |
| Snapshot codec (internal) | Snapshot encoding, signatures, and portable-value checks | Snapshot contract creation or review policy |
| `Jidoka.Harness` | Compatibility delegates | New execution logic |

Some small integration modules stay beside the port that they implement. For
example, `Jidoka.Operation.Source.MCP`, `Jidoka.Operation.Source.Catalog`, and
`Jidoka.Memory.Store.JidoMemory` are adapters under their owning port
namespaces. `Jidoka.Action` and the generated part of `Jidoka.Agent` are
compile-time Jido authoring edges. Large runtime translations use the explicit
`Jidoka.Adapter.*` namespace.

## Layer Purpose

### Public Facades

Use these modules in normal application code. They keep the common path short.
The root `Jidoka` module stays a small set of stable verbs.

### Application Composition And Use Cases

These modules coordinate work. Each module owns one kind of workflow:

- `Jidoka.Turn.Execution` owns a direct turn and snapshot resume.
- `Jidoka.Session.Execution` owns durable session work.
- `Jidoka.Review.Execution` owns human review work.
- The internal async chat module owns the async request lifecycle.

This split prevents session storage, review queues, and direct turns from
sharing one large harness module.

### Core Contracts

These modules are data and pure rules. They are the stable seams between the
DSL, runtime, stores, adapters, tests, and presentation modules.

`Jidoka.Turn.Transition` and `Jidoka.Session.Transitions` are the functional
core. They do not perform external work.

For a Zoi-backed contract, `@schema` describes the final struct after input
normalization. A constructor can accept aliases and external input forms, but
it must convert them before the final schema parse. Code must not maintain a
separate manual `t()` definition for the same struct. Supporting types can stay
separate when the schema refers to them with a precise Zoi schema or a
`typespec:` override.

### Runtime Effect Shell

The runtime plans effects and interprets them through injected functions and
capabilities. It does not call adapter or projection modules. It also does not
own provider SDK behavior, Jido process behavior, or Runic storage behavior.

### External Adapters

Adapters translate external libraries into Jidoka contracts. A dependency on
`Jidoka.Adapter.*` is a visible edge dependency.

Operation-source implementations are also adapters. They normalize actions,
catalogs, MCP tools, subagents, handoffs, workflows, skills, Ash resources, and
browser tools into one `Jidoka.Operation.Source` contract.

### Inspection And Presentation

The root `Jidoka.Projection` module only dispatches. Projection rules are split
by area, such as Jidoka.Projection.Turn, Jidoka.Projection.Effect, and
Jidoka.Projection.Session.

`Jidoka.Session.Replay` and the internal workflow graph module build read
models. They do not own durable session or workflow state.

Kino is an optional presentation edge. Its source guard prevents Kino modules
from entering a production build.

## API Levels

### Level 1: Recommended Public API

Start with `Jidoka`, `Jidoka.Agent`, `Jidoka.Session`, `Jidoka.Workflow`,
`Jidoka.Action`, and `Jidoka.Control`.

### Level 2: Advanced Stable Contracts

Use typed data and ports when an application needs more control. This level
includes `Jidoka.Agent.Spec`, `Jidoka.Turn.*`, `Jidoka.Effect.*`,
`Jidoka.Operation.Source`, `Jidoka.Session.Data`, `Jidoka.Session.Store`,
`Jidoka.Snapshot`, and `Jidoka.Review.*`.

### Level 3: Internal Implementation

`Jidoka.Runtime.*`, `Jidoka.Adapter.*`, `Jidoka.*.Execution`, and the domain
projection modules are implementation modules. Applications must not depend on
their internal details unless they accept a higher change risk.

`Jidoka.Harness` is a compatibility facade at this level. New code must use the
public facades.

HexDocs keeps only the current extension seams visible from these namespaces:
the capability types, local operation helper, operation-control context, Jido
action support, hosted-agent state, and ReqLLM support. They appear under
**Advanced Extension Support**, not under the primary application API.

### Level 4: Development And Test

`Jidoka.Kino.*` exists only in development and test builds. Do not call these
modules from production code.

## Why The Package Has Many Files

Jidoka brings several Jido ecosystem packages into one developer dependency.
The total feature scope is large: authoring, turns, tools, controls, durable
sessions, review, memory, workflows, process hosting, provider calls,
inspection, and notebooks.

Small owner modules make this scope visible. A large file count is not a sign
that the Jido base is poor. It is a sign that the package contains many separate
capabilities. The important measure is whether each capability crosses a clear,
tested seam. This architecture makes those seams explicit.
