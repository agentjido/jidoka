# Getting Started

This guide shows the smallest useful Jidoka flow: define an agent, attach one
Jido action, run one ReAct-style turn, and inspect the compiled spec.

## Install

From the package root:

```bash
mix deps.get
mix test
```

For live LLM calls, create a `.env` file:

```bash
cp .env.example .env
```

Then add one provider key:

```bash
OPENAI_API_KEY=...
# or
ANTHROPIC_API_KEY=...
```

## Define A Tool

Jidoka tools are Jido actions.

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
```

## Define An Agent

```elixir
defmodule MyApp.TimeAgent do
  use Jidoka.Agent

  agent :time_agent do
    model "openai:gpt-4o-mini"
    generation %{temperature: 0.0, max_tokens: 500}
    instructions "Call local_time when asked for the time."
  end

  tools do
    action MyApp.LocalTime
  end
end
```

## Inspect The Spec

The DSL compiles to `Jidoka.Agent.Spec`:

```elixir
spec = MyApp.TimeAgent.spec()
spec.id
#=> "time_agent"

Jidoka.Config.model_ref(spec.model)
#=> "openai:gpt-4o-mini"
```

The spec is definition data. It contains no live clients, processes, or API
keys.

## Import An Agent

The same Phase 1 agent shape can be imported from JSON or YAML:

```yaml
agent:
  id: time_agent
  model: openai:gpt-4o-mini
  generation:
    temperature: 0.0
    max_tokens: 500
  instructions: Call local_time when asked for the time.
tools:
  actions:
    - local_time
```

Runtime-only values are resolved through explicit registries:

```elixir
yaml = """
agent:
  id: time_agent
  model: openai:gpt-4o-mini
  generation:
    temperature: 0.0
    max_tokens: 500
  instructions: Call local_time when asked for the time.
tools:
  actions:
    - local_time
"""

{:ok, spec} =
  Jidoka.import(yaml,
    actions: %{"local_time" => MyApp.LocalTime}
  )
```

## Run A Turn

For live execution:

```elixir
{:ok, text} = MyApp.TimeAgent.chat("What time is it in Chicago?")
```

For deterministic tests, pass a fake LLM:

```elixir
llm = fn _intent, journal ->
  llm_calls =
    Enum.count(journal.results, fn {_id, result} ->
      result.kind == :llm
    end)

  case llm_calls do
    0 -> {:ok, %{type: :operation, name: "local_time", arguments: %{"city" => "Chicago"}}}
    1 -> {:ok, %{type: :final, content: "Chicago time is 09:30."}}
  end
end

{:ok, result} = MyApp.TimeAgent.run_turn("What time is it in Chicago?", llm: llm)
result.content
#=> "Chicago time is 09:30."
```
