# Structured Results

Structured results make the app-facing output explicit. The assistant text
stays in `Turn.Result.content`; validated data is returned as
`Turn.Result.value`.

## Declare A Result Schema

Use a Zoi schema in the agent block:

```elixir
defmodule MyApp.ProfileAgent do
  use Jidoka.Agent

  agent :profile_agent do
    instructions "Return a short profile summary."

    result schema: Zoi.object(%{
             name: Zoi.string(),
             score: Zoi.integer() |> Zoi.gte(0)
           }),
           max_repairs: 1
  end
end
```

The compiled spec contains `Jidoka.Agent.Spec.Result`:

```elixir
spec = MyApp.ProfileAgent.spec()
spec.result.max_repairs
#=> 1
```

## Model Decision Shape

The current provider-neutral decision protocol accepts a final text response
with a structured `result` value:

```elixir
%{
  type: :final,
  content: "Ada is ready.",
  result: %{"name" => "Ada", "score" => 10}
}
```

At runtime:

```elixir
{:ok, result} = Jidoka.turn(MyApp.ProfileAgent, "Summarize Ada.")

result.content
#=> "Ada is ready."

result.value
#=> %{name: "Ada", score: 10}
```

If the model omits `result` but returns JSON in `content`, Jidoka attempts to
decode and validate that JSON as the structured value.

## Repair Loop

If validation fails and `max_repairs` is greater than zero, Jidoka appends a
repair instruction to durable agent state and asks the model for another final
answer:

```elixir
result schema: Zoi.object(%{score: Zoi.integer()}), max_repairs: 1
```

If the repair bound is exhausted, `Jidoka.turn/3` returns a result-phase execution
error. The error includes the validation reason and repair count.

## Output Controls

Output controls run after validation and repair:

```elixir
defmodule MyApp.RequireHighConfidence do
  use Jidoka.Control, name: "require_high_confidence"

  @impl true
  def call(%{result_value: %{score: score}}) when score >= 8, do: :cont
  def call(_result), do: {:block, :low_confidence}
end
```

```elixir
controls do
  output MyApp.RequireHighConfidence
end
```

This keeps application policy close to the app-facing value, not the raw model
message.

## Import Shape

Portable JSON/YAML documents reference result schemas by name:

```yaml
agent:
  id: profile_agent
  instructions: Return a short profile summary.
  result:
    ref: profile_result
    max_repairs: 1
```

```elixir
{:ok, spec} =
  Jidoka.import(yaml,
    registries: %{
      result_schemas: %{
        "profile_result" =>
          Zoi.object(%{
            name: Zoi.string(),
            score: Zoi.integer() |> Zoi.gte(0)
          })
      }
    }
  )
```

## Testing

Use fake LLM decisions to make structured-output tests deterministic. Existing
coverage lives in:

- `test/integration/structured_result_integration_test.exs`
- `test/jidoka/runtime/req_llm/decision_test.exs`
