# Errors And Config Reference

Jidoka funnels every runtime-facing error through `Jidoka.Error` (a Splode
front end) and reads every default through `Jidoka.Config`. This reference
guide documents the error classes, the canonical helpers, and the full
defaults table. Use it when wiring telemetry, building app-facing error
formatters, or tuning application config.

## When To Use This

- Use this guide when you need to know the exact shape and category of a
  Jidoka error in logs, telemetry, or HTTP responses.
- Use this guide when you are configuring Jidoka defaults under `:jidoka` in
  your application config.
- Do not use this guide as a general onboarding doc; see
  [Getting Started](getting-started.md).

## Prerequisites

- You can compile and run the `:jidoka` test suite.
- You have basic familiarity with the Splode error library.

## Quick Example

Normalizing an arbitrary failure and turning it into wire data is two calls.

```elixir
case Jidoka.turn(MyApp.TimeAgent, "Hello") do
  {:ok, result} ->
    result

  {:error, reason} ->
    error = Jidoka.normalize_error(reason, phase: :turn)
    Jidoka.format_error(error)
    #=> "Jidoka execution failed."

    Jidoka.error_to_map(error)
    #=> %{category: :execution, message: "Jidoka execution failed.", phase: :turn, details: %{...}}
end
```

The same helpers are exported as [`Jidoka.Error.normalize/2`](`Jidoka.Error`),
`Jidoka.Error.format/1`, and `Jidoka.Error.to_map/1` for direct use inside the
package.

## Concepts

```diagram
╭──────────────╮     ╭─────────────────╮     ╭────────────────╮
│ raw reason   │────▶│ Jidoka.Error    │────▶│ Splode error   │
│ (atom, map,  │     │ .normalize/2    │     │ class struct   │
│  exception)  │     ╰─────────────────╯     ╰────────┬───────╯
╰──────────────╯                                      │
                                                      ▼
                                            ╭──────────────────╮
                                            │ Error.format/1   │
                                            │ Error.to_map/1   │
                                            ╰──────────────────╯
```

Splode error **classes** are buckets that group together specific error
structs. Every public Jidoka API returns either an `:ok` tuple or one of the
four classes.

## Fields

### Error Classes

| Class | Module | Splode `class` | Purpose |
| --- | --- | --- | --- |
| Invalid input / validation | [`Jidoka.Error.Invalid`](`Jidoka.Error.Invalid`) | `:invalid` | Callers passed bad data (missing input, invalid context, unsupported version). |
| Execution | [`Jidoka.Error.Execution`](`Jidoka.Error.Execution`) | `:execution` | Runtime-side failure (timeout, exceeded turns, capability returned `{:error, _}`). |
| Configuration | [`Jidoka.Error.Config`](`Jidoka.Error.Config`) | `:config` | App-level misconfiguration (missing module, invalid schema). |
| Internal | internal error wrapper | `:internal` | Unknown or unexpected failures wrapped as an internal unknown error. |

Each class is a Splode error class with an `errors:` list of one or more
concrete error structs (`ValidationError`, `ConfigError`, `ExecutionError`,
or `Internal.UnknownError`).

### Error Structs

| Struct | Fields | Used for |
| --- | --- | --- |
| `Jidoka.Error.ValidationError` | `:message`, `:field`, `:value`, `:details` | Invalid inputs (missing input, bad context, unknown agent). |
| `Jidoka.Error.ConfigError` | `:message`, `:field`, `:value`, `:details` | Config issues (missing agent module, invalid handler arity). |
| `Jidoka.Error.ExecutionError` | `:message`, `:phase`, `:details` | Runtime failures (turn timeout, exceeded turns, capability errors). |
| internal unknown error | `:message`, `:details`, `:error` | Catch-all for unexpected terms. |

`Jidoka.Error.validation_error/2`, `config_error/2`, and `execution_error/2`
are the canonical constructors. They take a message and either a keyword list
or map of details; the `:details` map is sanitized before any rendering.

### Public Helpers

The four most important error helpers, exported from both `Jidoka.Error` and
the top-level `Jidoka` facade:

| Helper | Returns | Use |
| --- | --- | --- |
| `Jidoka.normalize_error/2` | exception | Turn any reason (atom, tuple, struct) into a Jidoka/Splode exception. |
| `Jidoka.format_error/1` | string | Short, human-readable summary suitable for logs or UI. |
| `Jidoka.error_to_map/1` | map | JSON-friendly map with `:category`, `:message`, and structured details. |
| `Jidoka.Error.category/1` | `:validation \| :configuration \| :execution \| :internal \| :unknown` | Classify an already-normalized error. |

The `format/1` and `to_map/1` helpers automatically redact secret-like fields
(`api_key`, `authorization`, `password`, `secret`, `token`) and omit
high-cardinality fields (`messages`, `prompt`, `request_body`, etc.).

### `Jidoka.Config` Defaults

`Jidoka.Config` reads every default through `Application.get_env(:jidoka, key, fallback)`
and validates the value before returning.

| Helper | Config key (under `:jidoka`) | Fallback | Validator |
| --- | --- | --- | --- |
| `Jidoka.Config.default_model/0` | `:default_model` | `"openai:gpt-4o-mini"` | `normalize_model_spec!/2` (ReqLLM input). |
| `Jidoka.Config.default_generation/0` | `:default_generation` | `%{params: %{temperature: 0.0, max_tokens: 500}}` | `normalize_generation!/2`. |
| `Jidoka.Config.default_max_model_turns/0` | `:default_max_model_turns` | `8` | `normalize_positive_integer!/2`. |
| `Jidoka.Config.default_turn_timeout_ms/0` | `:default_turn_timeout_ms` | `30_000` | `normalize_positive_integer!/2`. |

Example application configuration:

```elixir
# config/config.exs
import Config

config :jidoka,
  default_model: "anthropic:claude-3-5-sonnet-latest",
  default_generation: %{params: %{temperature: 0.2, max_tokens: 1_024}},
  default_max_model_turns: 6,
  default_turn_timeout_ms: 45_000
```

Two additional `Jidoka.Config` helpers are worth knowing:

| Helper | Purpose |
| --- | --- |
| `Jidoka.Config.normalize_model_spec/2` | Validate any ReqLLM-supported model input without raising. |
| `Jidoka.Config.model_ref/1` | Render an `%LLMDB.Model{}` (or any input) back to a `"provider:id"` string for prompts, logs, and tests. |

## Common Patterns

- **Always normalize before logging.** Raw atoms or tuples lose context;
  `Jidoka.normalize_error/2` adds a category, message, and phase.
- **Use `error_to_map/1` at the wire boundary.** It is JSON-safe and applies
  secret redaction automatically.
- **Set defaults in config, not in agents.** `spec` overrides win, but
  `:jidoka` defaults are what unify behavior across modules.
- **Treat `:invalid` as a 4xx and `:execution` as a 5xx.** Mapping
  `Jidoka.Error.category/1` directly to HTTP status codes works well in
  practice.

## Testing

Error tests are most useful when they assert on both the category and the
relevant detail.

```elixir
test "missing input becomes a validation error" do
  error = Jidoka.normalize_error(:missing_input)

  assert Jidoka.Error.category(error) == :validation
  assert %{category: :validation, message: message} = Jidoka.error_to_map(error)
  assert message =~ "input is required"
end

test "config defaults round-trip" do
  Application.put_env(:jidoka, :default_max_model_turns, 12)
  assert Jidoka.Config.default_max_model_turns() == 12
after
  Application.delete_env(:jidoka, :default_max_model_turns)
end
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `ArgumentError: invalid default_model: ...` at boot | `:jidoka, :default_model` is not a valid ReqLLM input. | Use a `"provider:id"` string or a `%LLMDB.Model{}` struct. |
| Error map shows `category: :unknown` | The reason was never normalized. | Pipe through `Jidoka.normalize_error/2` first. |
| Logs leak API keys or large prompts | Direct `inspect/1` on the raw error. | Use `Jidoka.format_error/1` or `Jidoka.error_to_map/1`; both sanitize. |
| `{:error, {:turn_timeout_exceeded, _, _}}` rendered as a generic message | Helper not used. | `Jidoka.normalize_error/2` adds `phase: :turn` and structured details. |
| New error reason renders as `Jidoka execution failed.` | No dedicated normalizer matched. | That is the default Execution fallback; either add a specific normalizer or include the cause via the `context` argument. |

## Reference

- [`Jidoka.Error`](`Jidoka.Error`) - Splode entry point and helpers.
- [`Jidoka.Error.Invalid`](`Jidoka.Error.Invalid`) - validation error class.
- [`Jidoka.Error.Execution`](`Jidoka.Error.Execution`) - execution error
  class.
- [`Jidoka.Error.Config`](`Jidoka.Error.Config`) - configuration error class.
- [`Jidoka.Error.Internal`](`Jidoka.Error.Internal`) - internal error class
  (and `Internal.UnknownError`).
- [`Jidoka.Error.ValidationError`](`Jidoka.Error.ValidationError`),
  [`Jidoka.Error.ConfigError`](`Jidoka.Error.ConfigError`),
  [`Jidoka.Error.ExecutionError`](`Jidoka.Error.ExecutionError`).
- [`Jidoka.Config`](`Jidoka.Config`) - `default_model/0`,
  `default_generation/0`, `default_max_model_turns/0`,
  `default_turn_timeout_ms/0`, `normalize_model_spec/2`, `model_ref/1`.

## Related Guides

- [Getting Started](getting-started.md) - first encounter with defaults.
- [Agent Spec Contract](agent-spec-contract.md) - where `Spec` consumes
  `Jidoka.Config` defaults.
- [Turn And Effect Contracts](turn-and-effect-contracts.md) - the runtime
  phases that produce execution errors.
- [Runtime And Harness](runtime-and-harness.md) - where harness-side errors
  originate.
