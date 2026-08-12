# New Developer Journey

Date: 2026-08-02

This artifact reviews Jidoka as a developer who knows Elixir but does not know
Jido, ReqLLM, Runic, Spark, or the internal Jidoka runtime.

## The Job To Be Done

The developer wants to:

1. install one package;
2. define one agent;
3. call a model;
4. add an application function as a tool;
5. test without a provider;
6. keep conversation state;
7. protect unsafe work;
8. add advanced integrations only when needed.

Jidoka supports all of these jobs. The main issue is not missing capability. It
is deciding which of the many visible modules the developer should ignore.

## Recommended Golden Path

### Step 1: Install Jidoka

The developer adds one dependency:

```elixir
def deps do
  [
    {:jidoka, "~> 0.9.1"}
  ]
end
```

This supports the “one package” promise. The developer should not select Jido,
ReqLLM, Runic, Spark, or Zoi versions separately.

Public concepts learned: `Jidoka` as one package.

Current friction:

- the package version is repeated in several documents and will require coordinated
  edits;
- dotenv behavior is described from both the Jidoka and ReqLLM viewpoints;
- the production credential rule appears before the developer has run the
  first agent.

Recommendation: keep the first install section short. Put one clear ReqLLM
credential note after the first agent definition, then link to Configuration.

### Step 2: Define One Agent

```elixir
defmodule MyApp.Assistant do
  use Jidoka.Agent

  agent :assistant do
    model "openai:gpt-4o-mini"
    instructions "Answer clearly and briefly."
  end
end
```

Public concepts learned:

- `Jidoka.Agent`;
- `agent`, `model`, and `instructions` DSL terms;
- a model reference string.

This is a good first API. It is compact, and it does not expose processes,
capabilities, adapters, or workflow steps.

Current friction:

- the Agent DSL guide also shows a model-free minimal agent that uses
  application defaults;
- the new developer does not yet know whether explicit model selection or
  application configuration is the preferred default;
- the `Jidoka.Agent` module page does not act as a complete DSL reference.

Recommendation: use an explicit model in the first agent. Introduce the
configured default later as a production convention.

### Step 3: Run One Chat

Recommended canonical form:

```elixir
{:ok, text} = Jidoka.chat(MyApp.Assistant, "What can you help me with?")
```

Generated convenience form:

```elixir
{:ok, text} = MyApp.Assistant.chat("What can you help me with?")
```

Public concepts learned: `Jidoka.chat/3` and one simple result tuple.

Current friction: both forms appear early and look equally canonical. The
agent-local full-result function is named `run_turn/2`, while the root facade
uses `turn/3`.

Recommendation: teach the root facade first. Introduce the generated functions
in a short “agent shortcuts” section.

### Step 4: Inspect Before Spending Tokens

```elixir
{:ok, preflight} =
  Jidoka.preflight(MyApp.Assistant, "What can you help me with?")

preflight.prompt.messages
preflight.prompt.operations
```

This is one of the strongest parts of the current API. It helps the developer
understand the agent without learning the internal plan or effect runtime.

Public concepts learned: `Jidoka.preflight/3`.

Recommendation: keep preflight in Getting Started. Delay the larger
`Jidoka.inspect/2` output until the developer needs to debug the compiled
definition.

### Step 5: Add One Tool

```elixir
defmodule MyApp.LocalTime do
  use Jidoka.Action,
    name: "local_time",
    description: "Returns the local time for a city.",
    schema: Zoi.object(%{city: Zoi.string()})

  @impl true
  def run(%{city: city}, _context) do
    {:ok, %{city: city, time: "09:30"}}
  end
end

defmodule MyApp.TimeAgent do
  use Jidoka.Agent

  agent :time_agent do
    model "openai:gpt-4o-mini"
    instructions "Use local_time when the user asks for the time."
  end

  tools do
    action MyApp.LocalTime
  end
end
```

Public concepts learned:

- `Jidoka.Action`;
- a Zoi input schema;
- the `run/2` action callback;
- the `tools` block and `action` declaration.

This is still a reasonable learning step, but the vocabulary grows quickly.
The beginner needs one explicit definition:

> A tool is what the agent can request. An action is one implementation of a
> tool. Jidoka normalizes every declared tool into an operation for the model
> and runtime.

Open contract questions:

- Are action parameters always normalized to the atom-key shape declared by
  the Zoi schema?
- What exact map does the action receive as its context?
- Which return values are valid from `run/2`?
- Which `Jido.Action` options pass through `Jidoka.Action` and are stable in
  Jidoka?

The `Jidoka.Action` module page should answer these questions. Beginner
examples should not handle both atom and string keys unless that is an
intentional public requirement.

### Step 6: Get The Full Result

```elixir
{:ok, result} =
  Jidoka.turn(MyApp.TimeAgent, "What time is it in Chicago?")

result.content
result.value
result.usage
result.events
result.journal
```

Public concepts learned:

- `Jidoka.turn/3`;
- `Jidoka.Turn.Result`;
- optional result, usage, event, and journal data.

Recommendation: define a simple rule in all beginner documents:

- use `chat` for product text;
- use `turn` for typed result and evidence.

Do not require the developer to understand intent interpretation or the Runic
spine to use the result.

### Step 7: Test Without A Provider

The current simple LLM test has this shape:

```elixir
llm = fn _intent, _journal, _context ->
  {:ok, %{type: :final, content: "pong"}}
end

assert {:ok, "pong"} =
         Jidoka.chat(MyApp.Assistant, "ping", llm: llm)
```

This works, but it introduces the capability contract before the developer
needs it. A tool test also introduces `Jidoka.Effect.Journal` and
`Jidoka.Runtime.LocalOperations`.

The desired beginner shape is declarative:

```elixir
llm = Jidoka.Test.LLM.final("pong")

assert {:ok, "pong"} =
         Jidoka.chat(MyApp.Assistant, "ping", llm: llm)
```

For a tool loop:

```elixir
llm =
  Jidoka.Test.LLM.sequence([
    {:operation, "local_time", %{city: "Chicago"}},
    {:final, "It is 09:30 in Chicago."}
  ])

operations =
  Jidoka.Test.Operations.new(
    local_time: fn _args -> {:ok, %{time: "09:30"}} end
  )
```

These helper names are proposals. The important requirement is that the first
test does not require `Jidoka.Runtime.*`, `Jidoka.Adapter.*`, effect intents,
or journal structure.

### Step 8: Keep Conversation State

```elixir
{:ok, session} = Jidoka.session(MyApp.Assistant, "conversation-123")

{:ok, session, _text} =
  Jidoka.chat(session, "Remember that my team is Platform.")

{:ok, session, text} =
  Jidoka.chat(session, "What is my team?")
```

Public concepts learned:

- `Jidoka.session/2`;
- `Jidoka.Session.Data` as returned state;
- state threading when no durable store owns the session.

The overload is convenient, but the return shape changes from
`{:ok, text}` to `{:ok, session, text}`. State this next to the first session
example.

Recommended result table:

| Target passed to `chat/3` | Success shape |
| --- | --- |
| Agent, spec, plan, or hosted agent | `{:ok, text}` |
| Caller-managed session | `{:ok, updated_session, text}` |

### Step 9: Protect Unsafe Work

The easiest safe path is approval policy on the tool declaration:

```elixir
tools do
  action MyApp.RefundOrder,
    idempotency: :unsafe_once,
    approval: [reason: :refund_requires_review]
end
```

Then use only the root review verbs:

```elixir
{:hibernate, snapshot} = Jidoka.turn(MyApp.RefundAgent, request)
{:ok, [review]} = Jidoka.pending_reviews(snapshot)
{:ok, result} = Jidoka.approve(snapshot, review)
```

Public concepts learned: hibernation, snapshot, review request, and approval.

This is a good progressive path. Do not make the developer write a custom
operation control until approval sugar is not sufficient.

When a custom control is needed, the current callback accepts
`Jidoka.Runtime.Controls.OperationContext`. That type is part of agent
authoring and should have a public owner outside the runtime implementation
namespace.

### Step 10: Add Advanced Features Only When Needed

The developer can now select one feature path:

| Product need | Next public area |
| --- | --- |
| Structured application data | agent `result` schema and `Jidoka.Turn.Result.value` |
| Dynamic instructions | `Jidoka.Instructions` |
| Long-term memory | agent `memory` policy and `Jidoka.Memory` |
| UI event stream | `Jidoka.chat_async`, `Jidoka.Stream`, `Jidoka.Event` |
| Process-hosted agent | `Jidoka.start_agent` and `Jidoka.Jido` |
| Deterministic business process | `Jidoka.Workflow` |
| Remote tools | browser, MCP, Ash, or skill DSL entries |
| Multi-agent composition | workflow, subagent, or handoff DSL entries |

The developer should not read all integration guides before the first agent.

## Learning Budget

### First Useful Agent

Required Jidoka modules:

- `Jidoka`;
- `Jidoka.Agent`.

Required external concepts:

- one provider model id;
- one provider credential.

### First Tool Agent

Add:

- `Jidoka.Action`;
- Zoi schema basics;
- the tool/action/operation vocabulary.

### First Production Agent

Add only as needed:

- `Jidoka.Context`;
- `Jidoka.Control` or approval sugar;
- `Jidoka.Session`;
- `Jidoka.Stream` and `Jidoka.Event`;
- structured results;
- trace and error helpers.

### Extension Author

Only this user should need:

- `Jidoka.Agent.Spec.*`;
- `Jidoka.Turn.*`;
- `Jidoka.Effect.*`;
- `Jidoka.Operation.Source`;
- store and sink behaviors;
- adapter and runtime architecture guides.

## Documentation Path Recommendation

The beginner path should be four required pages:

1. Getting Started;
2. Agent DSL;
3. Tools And Operations;
4. Testing Agents.

Everything else should be a feature path. The current Documentation Overview
already moves in this direction, but the module index and cross-links still
make internals look like normal application choices.

## Developer Experience Acceptance Test

A release should pass this manual test:

1. A developer finds the install command from the package page.
2. The developer builds an agent without reading architecture documents.
3. The developer knows whether to call `Jidoka.chat` or the generated agent
   function.
4. The developer adds one action from the `Jidoka.Action` module page and one
   guide.
5. The developer writes an offline test without importing a runtime or adapter
   module.
6. The developer can identify Tier 1 API modules in the module index.
7. The developer does not mistake an adapter, execution owner, or turn runner
   for the main entry point.

The current package passes items 1, 2, and 4. It partly passes items 3 and 6.
It does not yet pass items 5 and 7.
