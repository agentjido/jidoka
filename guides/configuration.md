# Configuration

Configure Jidoka with a small set of application defaults. Provider keys stay
in the process environment, where ReqLLM reads them at call time.

## When To Use This

- Use this guide when you want to change the default model, generation
  parameters, loop budget, or turn timeout for a host application.
- Use this guide as a reference when wiring `:jidoka` into a Phoenix or umbrella
  project for the first time.
- Do **not** use this guide for per-agent configuration; those values live in
  the DSL or in the imported spec. See [Agent DSL](agent-dsl.md).
- Do **not** use this guide as a credential-management primer. Jidoka does
  not own provider auth; that is ReqLLM's responsibility.

## Prerequisites

- A working Jidoka DSL agent. See [Getting Started](getting-started.md).
- A `config/config.exs` (and ideally `config/runtime.exs`) in the host
  application.
- For live turns: provider credentials available in the runtime environment.

## Quick Example

A minimal `config/config.exs` for a Jidoka-backed application:

```elixir
import Config

config :jidoka,
  default_model: "openai:gpt-4o-mini",
  default_max_model_turns: 8,
  default_turn_timeout_ms: 30_000,
  default_generation: %{
    params: %{
      temperature: 0.0,
      max_tokens: 500
    }
  }

import_config "#{config_env()}.exs"
```

`Jidoka.Config` reads these keys on first use; agents that do not specify
their own `model`, `generation`, `max_model_turns`, or `timeout_ms` fall
through to these values.

## Concepts

```diagram
╭───────────────────────────╮
│ config/config.exs         │
│  config :jidoka, ...      │
╰─────────────┬─────────────╯
              │ Application.get_env(:jidoka, key)
              ▼
╭───────────────────────────╮
│ Jidoka.Config             │
│  default_model            │
│  default_generation       │
│  default_max_model_turns  │
│  default_turn_timeout_ms  │
╰─────────────┬─────────────╯
              │ used by
              ▼
╭───────────────────────────╮     ╭───────────────────────────╮
│ Jidoka.Agent.Spec         │     │ Turn.Plan defaults        │
│  (when DSL omits values)  │     │  (loop + timeout budget)  │
╰───────────────────────────╯     ╰───────────────────────────╯

╭───────────────────────────╮
│ Process environment       │
│  OPENAI_API_KEY           │
│  ANTHROPIC_API_KEY        │
│  GEMINI_API_KEY           │
╰─────────────┬─────────────╯
              │ read by
              ▼
╭───────────────────────────╮
│ ReqLLM                    │
│  per-call provider auth   │
╰───────────────────────────╯
```

Three concepts cover the config story:

1. **Four `:jidoka` keys.** `default_model`, `default_generation`,
   `default_max_model_turns`, and `default_turn_timeout_ms`. Each one has a
   built-in fallback inside `Jidoka.Config`, so the application config block
   is optional for development.
2. **Provider env vars.** Jidoka never reads provider keys; ReqLLM does, at
   call time. Setting `OPENAI_API_KEY` (or the equivalent for another
   provider) is enough.
3. **No dotenv loading.** The package does **not** load `.env` files. Set
   environment variables through your shell, your supervisor, or your
   deployment platform.

### Security / Trust Boundaries

- Provider credentials must not appear in `config/*.exs`. Compiled config is
  baked into releases; rotating a secret would force a redeploy and bake the
  old secret into release artifacts.
- Per-agent credentials, tenant ids, and actor data belong in the runtime
  context for a turn (`Jidoka.turn(spec, input, context: %{...})`), not in
  the application config.
- `Jidoka.Config.default_model/0` resolves the configured model through
  `ReqLLM.model/1`. That call validates the model id but does not contact a
  provider; configuration is still side-effect free.
- The four `:jidoka` keys are public defaults. Treat them as the floor of
  agent behaviour: any agent may raise the loop budget or timeout, but
  no agent should silently lower the floor by relying on missing config.
- `mix release` snapshots application config at build time. Use
  `config/runtime.exs` for any value that should be evaluated at boot, and
  read provider env vars through `System.fetch_env!/1` if you must surface
  them at boot rather than at call time.

## How To

### Step 1: Set The Default Model

The model is the value most callers want to override. The string form is
parsed by ReqLLM at first use.

```elixir
# config/config.exs
import Config

config :jidoka, default_model: "openai:gpt-4o-mini"
```

An agent that does not specify `model "..."` inherits this value. To pin a
specific agent, declare it in the DSL:

```elixir
agent :time_agent do
  model "anthropic:claude-3-5-sonnet"
end
```

### Step 2: Set Generation Defaults

Generation parameters control sampling. The default favours determinism for
tests; relax it for product code that wants creative output.

```elixir
config :jidoka,
  default_generation: %{
    params: %{
      temperature: 0.7,
      max_tokens: 1_024
    }
  }
```

`Jidoka.Config.default_generation/0` normalizes the value through
`Jidoka.Agent.Spec.Generation.from_input/1` and raises with a useful error if
the map is malformed.

### Step 3: Tune The Loop And Timeout Budget

Two integer keys cap a single turn's work.

```elixir
config :jidoka,
  default_max_model_turns: 6,
  default_turn_timeout_ms: 20_000
```

`default_max_model_turns` is the maximum number of model invocations inside
one tool loop; `default_turn_timeout_ms` is the wall-clock cap for the turn.
Both round-trip through `Jidoka.Config.normalize_positive_integer/2`, which
rejects zero and negative values with a clear error.

### Step 4: Layer Env-Specific Overrides

The standard `config/{dev,test,prod}.exs` layering applies to `:jidoka` like
any other application:

```elixir
# config/dev.exs
import Config
config :jidoka, default_model: "openai:gpt-4o-mini"
```

```elixir
# config/test.exs
import Config

config :jidoka,
  default_model: %{provider: :test, id: "model"},
  default_generation: %{params: %{temperature: 0.0, max_tokens: 200}},
  default_max_model_turns: 4,
  default_turn_timeout_ms: 5_000
```

```elixir
# config/prod.exs
import Config
config :jidoka, default_model: "openai:gpt-4o-mini"
```

The `:test` model lets the deterministic test path bypass any real provider
client.

### Step 5: Evaluate Late-Bound Values At Runtime

`config/runtime.exs` runs after release start. Use it to source values from
the environment without baking them into the release artifact:

```elixir
# config/runtime.exs
import Config

if model = System.get_env("JIDOKA_DEFAULT_MODEL") do
  config :jidoka, default_model: model
end

if budget = System.get_env("JIDOKA_DEFAULT_MAX_TURNS") do
  config :jidoka, default_max_model_turns: String.to_integer(budget)
end
```

### Step 6: Export Provider Credentials Where The Application Can See Them

Jidoka does not read `.env` files. ReqLLM reads `OPENAI_API_KEY` and similar
env vars at call time. In development, export them in the shell:

```bash
export OPENAI_API_KEY=...
export ANTHROPIC_API_KEY=...
```

In production, use the deployment platform's secret manager (systemd
`EnvironmentFile`, Fly secrets, AWS Parameter Store, Kubernetes secrets) so
that the BEAM process sees them at boot. Inside Livebook, prefer the `LB_*`
prefix and mirror with `Jidoka.Kino.load_provider_env/1`. See
[Kino Notebooks](kino-notebooks.md).

## Common Patterns

- **Keep `config.exs` minimal.** The four `:jidoka` keys plus an
  `import_config "#{config_env()}.exs"` line is enough for most apps.
- **Pin a deterministic model in `config/test.exs`.** `%{provider: :test, id:
  "model"}` keeps tests fully reproducible.
- **Lower the loop budget in tests.** A short `default_max_model_turns`
  surfaces runaway loops fast.
- **Treat provider env vars as out-of-band configuration.** Document the
  required vars in the host application's README; do not try to encode them
  in `:jidoka` keys.

## What Does Not Belong In `:jidoka` Config

- Per-agent overrides. Use the DSL: `model "..."`, `generation %{...}`,
  `controls do max_turns ... end`.
- Provider credentials. Use the process environment.
- Per-tenant or per-actor values. Use the runtime context passed to
  `Jidoka.turn/3` or `Jidoka.chat/3`.
- Operation source registrations (`ash_resources`, `mcp_endpoints`). Those
  belong in the supervision tree (`Jido.MCP.register_endpoint/1`) or the
  agent module.
- Live LLM endpoints, request retries, or rate limits. Those live in ReqLLM
  config (`config :req_llm, ...`) or in the host's own request pipeline.

## Testing

The configuration helpers are pure functions over `Application.get_env/3`,
so they are easy to test in isolation:

```elixir
defmodule MyApp.JidokaConfigTest do
  use ExUnit.Case, async: false

  setup do
    previous_model = Application.get_env(:jidoka, :default_model)

    on_exit(fn ->
      if previous_model do
        Application.put_env(:jidoka, :default_model, previous_model)
      else
        Application.delete_env(:jidoka, :default_model)
      end
    end)

    :ok
  end

  test "model defaults are normalized through ReqLLM" do
    Application.put_env(:jidoka, :default_model, "openai:gpt-4o-mini")
    assert Jidoka.Config.model_ref(Jidoka.Config.default_model()) == "openai:gpt-4o-mini"
  end

  test "invalid positive integer raises" do
    assert_raise ArgumentError, ~r/invalid default_max_model_turns/, fn ->
      Jidoka.Config.normalize_positive_integer!(0, :default_max_model_turns)
    end
  end
end
```

Avoid `async: true` for tests that mutate `Application` env. The setup above
also captures and restores the previous value so the suite does not leak
state.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `ArgumentError: invalid default_model: ...` | The configured model string is not parseable by ReqLLM. | Use a `provider:id` string or a `%{provider:, id:}` map. |
| `ArgumentError: invalid default_max_model_turns: ...` | The value is zero, negative, or not an integer. | Use a positive integer; strings are parsed when they trim to one. |
| `{:error, :missing_provider_credentials}` from a live turn | The provider env var is not set in the BEAM process. | Export the var before starting the application or set it through your deployment platform. |
| Config changes do not take effect after deploy | `config/config.exs` is compiled into the release. | Move late-bound values to `config/runtime.exs`. |
| Tests interfere with each other on `:jidoka` config | A test mutated `Application.put_env/3` without an `on_exit` restore. | Capture the previous value in `setup` and restore it on exit. |

## Reference

Key modules touched in this guide:

- [`Jidoka.Config`](`Jidoka.Config`) - typed accessors for `default_model/0`,
  `default_generation/0`, `default_max_model_turns/0`,
  `default_turn_timeout_ms/0`, and the `normalize_*` helpers.
- [`Jidoka.Agent.Spec.Generation`](`Jidoka.Agent.Spec.Generation`) - shape of
  the generation map normalized from `default_generation`.
- [`Jidoka`](`Jidoka`) - the facade that reads defaults when a turn does not
  override them.

## Related Guides

- [Getting Started](getting-started.md) - the smallest DSL agent end to end.
- [Agent DSL](agent-dsl.md) - per-agent overrides for the four defaults.
- [Errors And Config Reference](errors-and-config-reference.md) - the full
  list of error structs and config keys.
- [Jido Process Integration](jido-process-integration.md) - supervising
  Jidoka agents alongside the default `Jidoka.Jido` runtime.
- [Kino Notebooks](kino-notebooks.md) - mirroring `LB_*` secrets into
  provider env vars for Livebook.
