# Documentation Alignment Plan

Date: 2026-08-02

Status: Implemented on 2026-08-02. This document does not define a
compatibility contract.

## Implementation Result

- The root `Jidoka` facade is the canonical invocation path in application
  guides and examples.
- ExDoc separates application APIs, optional features, public contracts,
  advanced extension support, and development-only modules.
- Implementation-only module pages are hidden from the normal module index.
  The visible Jidoka module count decreased from 150 to 129.
- Feature, contract, integration, and maintainer guides state their owners and
  boundaries.
- Five example applications and nine Livebooks use the aligned public path and
  pass deterministic execution checks.
- CI now enforces ExDoc warnings, local links, package versions, credential
  guidance, public invocation rules, example manifests, and executable
  Livebooks.

## Outcome

Align the documentation with the current Jidoka feature set before more
features enlarge the public surface.

After this work, a new developer must be able to:

1. install Jidoka;
2. define one agent;
3. run it through the `Jidoka` facade;
4. add one action as a tool;
5. inspect and test the agent without a provider;
6. add state, controls, or composition only when the application needs them.

The documentation must show this short path without presenting runtime and
adapter modules as equal alternatives.

## Scope

This plan covers:

- the README;
- 45 Markdown guides;
- four guide Livebooks;
- five complete example applications;
- ExDoc guide and module groups;
- public module documentation that supports the developer journey;
- documentation warning, link, and example checks.

This plan does not include:

- new runtime features;
- a new test helper API;
- public module moves or renames;
- changes to current return values;
- a full visual redesign of HexDocs;
- release notes.

If documentation work finds an API problem, record the problem in the public
API audit. Do not document a proposed API as if it exists.

## Current Baseline

| Measure | Current value |
| --- | ---: |
| Markdown guides | 45 |
| Guide lines | 15,255 |
| Guide Livebooks | 4 |
| Complete example applications | 5 |
| Visible Jidoka module pages | 150 |
| Compiled Jidoka modules | 329 |
| Root `Jidoka` functions | 32 |
| ExDoc warning gate | Fails |

The current guides cover the feature set. The main problems are navigation,
overlap, conflicting statements, and weak separation between application API
and implementation details.

## Proposed Documentation Decisions

These decisions apply to all work in this plan.

### One Main Invocation Style

Use these calls in the main developer path:

```elixir
Jidoka.chat(MyApp.Assistant, input)
Jidoka.turn(MyApp.Assistant, input)
Jidoka.preflight(MyApp.Assistant, input)
Jidoka.inspect(MyApp.Assistant)
```

Describe generated calls such as `MyApp.Assistant.chat/2` one time as
shortcuts. Do not alternate between the two styles in beginner examples.

### One Meaning For Each Tool Term

Use these terms consistently:

- **tool**: an item that an agent author declares in the `tools` block;
- **action**: one Elixir implementation type that can supply a tool;
- **operation**: the normalized contract that the model and runtime use.

The Getting Started guide owns the short explanation. The Tools And
Operations guide owns the complete explanation. The glossary owns the formal
definitions.

### One Public Path Before Extension Paths

Application guides must show the root facade and public DSL first. Extension
contracts can follow in an advanced section. Runtime, adapter, execution, and
projection internals belong in maintainer guides.

### Current Features Only

Examples must use APIs that exist in the current package. For example, the
testing guide can explain the current injected capability functions, but it
must not show the proposed `Jidoka.Test.LLM` API as current behavior.

### One Credential Statement

Use this meaning in all start and configuration material:

> Jidoka does not implement dotenv loading. ReqLLM loads `.env` by default.
> Set `config :req_llm, load_dotenv: false` when the host owns credentials.

### Stable File Names During The First Pass

Keep current guide file names during the alignment. This preserves existing
links. Change sidebar groups and page titles when needed. Consider file
renames only after the content passes all gates.

## Target Reader Paths

### New Application Developer

This is the primary path:

1. Getting Started;
2. Agent DSL;
3. Tools And Operations;
4. Testing And Evals;
5. Sessions And Stores, when state is required;
6. one optional feature guide.

The first four pages must be sufficient to build and test a useful
tool-enabled agent.

### Production Operator

This path covers configuration, state, recovery, safety, observation, and
troubleshooting. It must not require knowledge of the turn runner or effect
interpreter.

### Extension Author

This path covers typed contracts, stores, operation sources, controls, and
integrations. It can use lower-level types, but it must identify which types
are stable extension contracts.

### Jidoka Maintainer

This path covers the Runic workflow, effect shell, runtime capabilities,
adapters, projections, and contributor tests. It must state that these pages
describe implementation and not a second application API.

## Target HexDocs Tree

The target tree keeps all 45 current guides. It changes their order and
purpose.

```text
Start Here
├── Getting Started
├── Documentation Overview
└── Core Concepts

Build Agents
├── Agent DSL
├── Tools And Operations
├── Structured Results
├── Controls
├── Memory
├── Import (JSON/YAML)
├── Inspection And Preflight
└── Testing And Evals

Compose Work
├── Workflows
├── Agent Orchestration
└── Handoffs

Operate Agents
├── Configuration
├── Sessions And Stores
├── Snapshots And Resume
├── Human In The Loop
├── Tracing And Events
├── Streaming
├── Agent View
└── Idempotency And Safety

Integrations
├── Live LLM Tool Loop
├── Jido Process Integration
├── AshJido Resources
├── Browser Tools
├── MCP Tools
├── Skill, Workflow, And Subagent Tools
└── Kino Notebooks

Public Contract Reference
├── Public Facade
├── Agent Spec Contract
├── Turn And Effect Contracts
├── Operation Source Contracts
├── Memory Contracts
├── Import And Snapshot Contracts
└── Errors And Config Reference

Architecture And Internals
├── Architecture Boundaries
├── Runtime And Execution Layers
├── Runic Spine Internals
├── Turn Runner And Effect Interpreter
├── Runtime Capabilities Internals
├── Projection Internals
└── Contributor Testing

Help
├── Glossary
└── Troubleshooting
```

Important moves in the sidebar:

- Move Configuration from Start Here to Operate Agents.
- Move Public Facade from Start Here to Public Contract Reference.
- Move Runtime And Execution Layers from Operate Agents to Architecture And
  Internals.
- Give composition its own group so workflows, orchestration, and handoffs do
  not enlarge the basic agent path.

## Content Ownership

Each repeated subject must have one owner. Other pages must give a short
summary and link to that owner.

| Subject | Owner | Other pages do |
| --- | --- | --- |
| Installation and first run | Getting Started | Link to it |
| Provider credentials and dotenv | Configuration | Use the same short statement |
| Main facade and result shapes | Public Facade | Show only the calls needed for the local task |
| Agent DSL | Agent DSL | Show a minimal local block |
| Tool, action, and operation terms | Tools And Operations | Use the terms without redefining them |
| Runtime data model | Core Concepts | Link before advanced contract detail |
| Deterministic tests and evals | Testing And Evals | Show one small local assertion at most |
| Sessions and store ownership | Sessions And Stores | Link from stateful examples |
| Pause, review, and resume | Human In The Loop | Controls explains policy; Snapshots explains persistence |
| Errors | Errors And Config Reference | Troubleshooting maps symptoms to checks |
| Internal dependency direction | Architecture Boundaries | Other internal guides describe one layer |
| Formal vocabulary | Glossary | Link instead of adding new local definitions |

## Work Plan

### Phase 1: Restore Documentation Truth

Goal: make all existing claims internally consistent and make ExDoc pass its
warning gate.

Work:

1. Fix ExDoc references to the hidden `Jidoka.Agent.RuntimeOptions`,
   `Jidoka.Workflow.Resolver`, `Jidoka.Snapshot.Codec`, `Jidoka.Chat.Async`,
   and `Jidoka.Workflow.Graph` modules in Architecture Boundaries.
2. Fix the `Jidoka.Chat.Request` module documentation link to the hidden
   `Jidoka.Chat.Async` module.
3. Fix the conflicting dotenv text in Configuration.
4. Check the same statement in the README and Getting Started.
5. Check all version strings and dependency examples against `mix.exs`.
6. Run ExDoc with warnings as errors.

Exit gate:

```bash
mix docs --warnings-as-errors
```

The command must pass before broad copy changes start.

### Phase 2: Align The New Developer Journey

Goal: make one path from installation through the first deterministic test.

Files:

- `README.md`;
- `guides/getting-started.md`;
- `guides/documentation-overview.md`;
- `guides/core-concepts.md`;
- `guides/public-facade.md`;
- `guides/agent-dsl.md`;
- `guides/tools-and-operations.md`;
- `guides/testing-and-evals.md`.

Required changes:

1. Use `Jidoka.chat/3` as the canonical first call.
2. Define tool, action, and operation before the first action example.
3. Show `preflight/3` before a live tool call.
4. Add a small table for the result shapes of `chat/3`, `turn/3`, and session
   chat.
5. State that generated agent functions are convenience calls.
6. Put advanced runtime capability details after the first simple test.
7. Do not imply that the current deterministic tool test has a high-level
   helper when it does not.
8. Limit the end of Getting Started to three primary next steps and one
   documentation-map link.

Exit gate:

A reviewer can follow Getting Started, add the first tool, and reach the first
provider-free test without choosing between two invocation styles.

### Phase 3: Separate Public Documentation From Internals

Goal: make the application surface easy to identify in HexDocs.

Work:

1. Apply the target guide groups in `mix.exs`.
2. Group the 32 root facade functions by job.
3. Replace current module groups with explicit application, extension,
   integration, and internal groups.
4. Hide implementation-only module pages from the normal module index.
5. Keep a module visible only when it supplies a public function, macro,
   callback, type, or data contract.
6. Do not hide a module that an application guide still requires. Record that
   dependency as an API seam for later code work.

This phase must use the existing Module Surface audit as its checklist. It
must not move code or rename modules.

Exit gate:

A developer who reads an application guide does not have to choose between
`Jidoka.turn/3`, an Execution module, and a Runtime runner.

### Phase 4: Tighten Feature Guides

Goal: give every current feature one clear guide and one place in the learning
order.

#### Batch A: Agent Authoring

| Guide | Planned change |
| --- | --- |
| Agent DSL | Keep the DSL as the owner; remove runtime explanations that belong to internals |
| Tools And Operations | Own tool vocabulary and normalized operation behavior |
| Structured Results | Start with the result DSL and show validation outcomes |
| Controls | Show public control authoring first; isolate the current operation-context seam |
| Memory | Separate prompt recall, writes, and durable store responsibilities |
| Import (JSON/YAML) | Show trust, normalization, validation, and safe input handling |
| Inspection And Preflight | Make preflight the first diagnostic action |
| Testing And Evals | Put basic deterministic tests before journal-driven advanced tests |

#### Batch B: Composition

| Guide | Planned change |
| --- | --- |
| Workflows | Keep the smallest workflow first; move scheduling and dynamic work later |
| Agent Orchestration | Start with a decision table for workflow, subagent, and handoff |
| Handoffs | Separate routing ownership from delegated work and session state |

#### Batch C: State And Operations

| Guide | Planned change |
| --- | --- |
| Configuration | Own all environment, provider, model, timeout, and dotenv claims |
| Sessions And Stores | Add the target-dependent result-shape table and store ownership rule |
| Snapshots And Resume | Separate persistence from approval policy |
| Human In The Loop | Own review lifecycle and facade approval calls |
| Tracing And Events | Lead with application observation; place event contract detail later |
| Streaming | Lead with `chat_async/3`, `stream/2`, and `await/2` |
| Agent View | Explain its UI projection job and its relation to events |
| Idempotency And Safety | State which guarantees exist and which remain application duties |

#### Batch D: Integrations

| Guide | Planned change |
| --- | --- |
| Live LLM Tool Loop | Keep as the explicit network and provider path |
| Jido Process Integration | Separate process hosting from normal direct calls |
| AshJido Resources | State package, setup, and public boundary requirements |
| Browser Tools | State external process and safety requirements before examples |
| MCP Tools | State transport, trust, and operation-name behavior |
| Skill, Workflow, And Subagent Tools | Keep a decision table and one example for each source |
| Kino Notebooks | State that Kino is a development or test integration |

#### Batch E: Contract Reference

| Guide | Planned change |
| --- | --- |
| Public Facade | Become the complete facade picker and result-shape reference |
| Agent Spec Contract | State normalized fields, input trust, and construction paths |
| Turn And Effect Contracts | State which types extension authors can depend on |
| Operation Source Contracts | State source input, normalization, conflicts, and errors |
| Memory Contracts | State read, write, key, and store contracts without repeating the feature tutorial |
| Import And Snapshot Contracts | State versioning, trust, and compatibility rules |
| Errors And Config Reference | Own stable error categories and configuration key tables |

#### Batch F: Maintainer Material

| Guide | Planned change |
| --- | --- |
| Architecture Boundaries | Remain the map of layers and dependency direction |
| Runtime And Execution Layers | Move to internals and remove application-path language |
| Runic Spine Internals | Cover only pure workflow planning and transitions |
| Turn Runner And Effect Interpreter | Cover only the effect shell and replay boundary |
| Runtime Capabilities Internals | Cover injected ports, default capabilities, and adapters |
| Projection Internals | Cover stable projections versus internal raw data |
| Contributor Testing | Own repository commands, suites, and quality gates |

#### Batch G: Help

| Guide | Planned change |
| --- | --- |
| Glossary | Apply the selected vocabulary and remove competing definitions |
| Troubleshooting | Organize by symptom and link to one owner guide for each fix |

Exit gate:

Each feature has one tutorial owner, one contract owner when needed, and no
competing beginner path.

### Phase 5: Align Examples And Livebooks

Goal: make executable material follow the same path and terms as HexDocs.

Example order:

1. Getting Started;
2. Support Agent;
3. Warranty Claim;
4. Durable Refund;
5. Workflow Composition.

| Example | Documentation job |
| --- | --- |
| Getting Started | Prove the smallest deterministic agent and first test |
| Support Agent | Prove one controlled tool call, review, snapshot, and resume |
| Warranty Claim | Prove typed context, media input, model policy, and structured result repair |
| Durable Refund | Prove async work, limits, durable recovery, replay, and fork |
| Workflow Composition | Prove direct, tool-owned, background, and scheduled workflow execution |

| Guide Livebook | Alignment job |
| --- | --- |
| Contracts And Runtime | Mark public contracts and internal runtime material clearly |
| Controls, Sessions, And Human Review | Use the facade and the documented result shapes |
| Import, Eval, And Trace | Use the same trust, test, and observation terms as the owner guides |
| Workflows | Follow the same smallest-to-advanced order as the Workflows guide |

Work:

1. Use the root facade in application-facing example code where possible.
2. Keep deterministic behavior as the default for repository examples.
3. Mark live provider calls clearly.
4. Give every example README the same sections: purpose, features, file
   order, command, expected result, and next guide.
5. Check that the four guide Livebooks use the same terms and public paths.
6. Keep adapter or runtime setup in an explicit integration or test section.
7. Keep Kino code out of the production documentation path.

Exit gate:

Every documented command runs, and each example links back to the guide that
owns its main feature.

### Phase 6: Add Documentation Quality Gates

Goal: stop later feature work from causing the same drift.

Required gates:

- ExDoc has no warnings.
- All local Markdown links resolve.
- All example manifests pass.
- All compiled snippets or doctests pass where the repository supports them.
- No Start Here guide links an application developer to a hidden module.
- No application guide presents Runtime, Adapter, or Execution modules as the
  normal invocation path.
- The current version in installation examples matches the package version.
- The README and Getting Started use the same credential statement.

Place the commands in Contributor Testing and in the release checklist. Add
automation only where it can produce a deterministic result.

## Standard For Each Guide

Each guide must answer these questions in this order:

1. What job does this feature do?
2. When should an application use it?
3. What is the smallest current example?
4. Which public modules and facade calls does it use?
5. What input and result shapes must the developer handle?
6. What state, effects, or external services does it own?
7. How can the developer test or inspect it?
8. What are the common failures?
9. Which guide is the next step?

Additional rules:

- Put the smallest working example before architecture details.
- Use one term for one concept.
- Use one owner guide for repeated claims.
- State current limits directly.
- Mark internal modules as internal when they must appear.
- Do not use a module link only to explain who implements an internal job.
- Keep related-guide lists short and ordered by likely next use.

## Proposed Commit Sequence

Use focused Conventional Commits during implementation:

1. `docs: fix documentation truth and warning failures`
2. `docs: align the new developer journey`
3. `docs: separate public and internal documentation`
4. `docs: tighten agent authoring guides`
5. `docs: tighten composition and operations guides`
6. `docs: align integrations and contract references`
7. `docs: align examples and livebooks`
8. `test: enforce documentation quality gates`

Do not combine all guide changes into one commit. A reviewer must be able to
review terminology, navigation, and technical claims in separate changes.

## Review Checkpoints

Stop for review after these points:

1. **Truth checkpoint:** ExDoc passes and conflicting claims are removed.
2. **Journey checkpoint:** the new developer path has one invocation style.
3. **Surface checkpoint:** the proposed guide and module groups show clear
   public tiers.
4. **Feature checkpoint:** all current features have an owner guide.
5. **Release checkpoint:** examples, links, and documentation commands pass.

## Completion Definition

The alignment is complete when:

- Getting Started builds one tool-enabled agent through one public path;
- the first provider-free test uses only APIs that exist in the package;
- optional features do not interrupt the first-agent path;
- application guides do not present implementation modules as equal choices;
- every current feature appears in the documentation map;
- module pages show a clear application and extension surface;
- ExDoc, links, examples, and documentation checks pass;
- future feature work has an explicit documentation owner and public tier.

At that point, feature-parity work can continue without widening the public
documentation surface by accident.
