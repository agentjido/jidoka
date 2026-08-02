# Getting Started

Build one agent, call a real model, then add one tool.

Jidoka agents are Elixir modules. The DSL compiles to `Jidoka.Agent.Spec`
data, and the runtime handles model calls, tool calls, sessions, and resume.

If you are working in the Jidoka source checkout, run the deterministic
[Getting Started example](../examples/getting_started/README.md):

```bash
mix run examples/getting_started/example.exs
```

It uses the same basic agent shape as this guide, but it injects a local model
function. You can run it without a provider key or network access.

## Install

Add Jidoka to your application:

```elixir
def deps do
  [
    {:jidoka, "~> 0.8.0-beta.1"}
  ]
end
```

Fetch and compile:

```bash
mix deps.get
mix compile
```

Export a provider key before running live examples:

```bash
export OPENAI_API_KEY=...
# or
export ANTHROPIC_API_KEY=...
```

ReqLLM is a Jidoka runtime dependency. By default, ReqLLM loads `.env` from the
current working directory when the application starts. Existing system
environment values take priority.

Disable automatic loading when your application or deployment platform owns
credential loading:

```elixir
# config/runtime.exs
import Config

config :req_llm, load_dotenv: false
```

For production, provide credentials through the deployment environment or a
secret manager.

## Define An Agent

Start with the shortest useful agent:

```elixir
defmodule MyApp.Assistant do
  use Jidoka.Agent

  agent :assistant do
    model "openai:gpt-4o-mini"
    instructions "Answer clearly and briefly."
  end
end
```

Generation settings are optional. Jidoka uses
`Jidoka.Config.default_generation/0` unless the agent overrides them.

## Run A Chat

Use `chat/3` when you only need the assistant's final text:

```elixir
{:ok, text} = MyApp.Assistant.chat("What can you help me with?")
```

The same call can go through the facade:

```elixir
{:ok, text} = Jidoka.chat(MyApp.Assistant, "What can you help me with?")
```

## Inspect The Prompt

Use `preflight/3` before spending tokens on a confusing agent:

```elixir
{:ok, preflight} =
  Jidoka.preflight(MyApp.Assistant, "What can you help me with?")

preflight.prompt
#=> %{
#=>   model: "openai:gpt-4o-mini",
#=>   messages: [
#=>     %{role: :system, content: "Answer clearly and briefly."},
#=>     %{role: :user, content: "What can you help me with?"}
#=>   ],
#=>   operations: [],
#=>   result: nil,
#=>   memory: nil,
#=>   context: %{},
#=>   generation: %{temperature: 0.0, max_tokens: 500},
#=>   loop_index: 0
#=> }

preflight.timeline
#=> [
#=>   %{
#=>     event: :prompt_assembled,
#=>     phase: :assemble_prompt,
#=>     category: :workflow,
#=>     status: :completed,
#=>     agent_id: "assistant",
#=>     loop_index: 0,
#=>     ...
#=>   }
#=> ]
```

Use `inspect/2` when you want the compiled agent shape:

```elixir
Jidoka.inspect(MyApp.Assistant)
#=> %{
#=>   kind: :agent,
#=>   module: "MyApp.Assistant",
#=>   spec: %{
#=>     id: "assistant",
#=>     model: "openai:gpt-4o-mini",
#=>     instructions: "Answer clearly and briefly.",
#=>     operations: [],
#=>     controls: %{
#=>       max_turns: nil,
#=>       timeout_ms: nil,
#=>       inputs: [],
#=>       operations: [],
#=>       outputs: []
#=>     }
#=>   },
#=>   plan: %{
#=>     spec_id: "assistant",
#=>     workflow_profile: :tool_loop,
#=>     max_model_turns: 8,
#=>     timeout_ms: 30000,
#=>     phases: [
#=>       :assemble_prompt,
#=>       :plan_model_effect,
#=>       :apply_model_result,
#=>       :plan_operation_effects,
#=>       :apply_operation_results
#=>     ]
#=>   }
#=> }
```

That is the useful part: `preflight/3` shows the exact messages and tools the
model would receive, while `inspect/2` shows the compiled spec and turn plan.
Neither call contacts a provider.

## Add A Tool

Tools are Jido actions exposed to the model as operations.

```elixir
defmodule MyApp.LocalTime do
  use Jidoka.Action,
    name: "local_time",
    description: "Returns the local time for a city.",
    schema: Zoi.object(%{city: Zoi.string() |> Zoi.default("Chicago")})

  @impl true
  def run(params, _context) do
    city = Map.get(params, :city) || Map.get(params, "city") || "Chicago"
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

Run it with the same `chat/3` call:

```elixir
{:ok, text} = MyApp.TimeAgent.chat("What time is it in Chicago?")
```

The model decides whether to call `local_time`. Jidoka runs the action, feeds
the result back to the model, and returns the final answer.

## Get The Full Turn

Use `turn/3` when you need events, the turn journal, structured output, or a
hibernation snapshot:

```elixir
{:ok, result} =
  Jidoka.turn(MyApp.TimeAgent, "What time is it in Chicago?")

result.content
result.usage
result.events
result.journal.results
```

Product code usually starts with `chat/3`. Tests, traces, and UIs often need
`turn/3`.

## Keep A Conversation

Use `Jidoka.Session` for multi-turn state:

```elixir
{:ok, session} = Jidoka.session(MyApp.Assistant, "demo-conversation")

{:ok, session, text} =
  Jidoka.chat(session, "Remember that my team is called Platform.")

{:ok, session, text} =
  Jidoka.chat(session, "What is my team called?")
```

Sessions can use in-memory stores for development and custom stores for
production.

## Test Without A Provider

User-facing docs use real models. Tests should not.

For deterministic tests, inject fake `llm:` and `operations:` capabilities.
See [Testing And Evals](testing-and-evals.md) for the full pattern.

## Common Mistakes

| Symptom | Fix |
| --- | --- |
| `{:error, :missing_provider_credentials}` | Export `OPENAI_API_KEY` or another provider key supported by ReqLLM. |
| The model does not call your tool | Check `Jidoka.preflight/3` and make sure the tool description tells the model when to use it. |
| `chat/3` returns `{:hibernate, snapshot}` | A control paused the turn. Use `Jidoka.resume/2` with an approval response. |
| You need the operation result | Use `turn/3` and inspect `result.journal.results`. |
| You need repeatable tests | Use fake capabilities from [Testing And Evals](testing-and-evals.md). |

## Next

- [Getting Started Example](../examples/getting_started/README.md) - the
  deterministic command runner, test, and Livebook for this guide.
- [Agent DSL](agent-dsl.md) - the full agent DSL.
- [Tools And Operations](tools-and-operations.md) - actions, browsers, MCP,
  workflows, and subagents.
- [Sessions And Stores](sessions-and-stores.md) - durable conversations.
- [Controls](controls.md) - input, operation, output, and human review.
- [Core Concepts](core-concepts.md) - the data model behind Jidoka.
