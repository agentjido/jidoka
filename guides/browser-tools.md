# Browser Tools

This guide explains how to give an agent constrained read-only access to the
web through the `browser` tool source. The DSL expands one `browser` entity
into a small set of Jido actions (search, page read, snapshot), wraps each one
with runtime policy (public-URL validation, allowlists, content truncation),
and tags the operations with stable metadata. By the end you will be able to
expose a search-only agent, switch to read-only browsing with an allowlist,
and confirm the runtime is blocking private and loopback hosts.

## When To Use This

- Use this guide when an agent needs to read public documentation, search the
  web, or snapshot a page as evidence for an answer.
- Use this guide when you want one DSL entry to expose a consistent, safe
  browser surface across agents.
- Do **not** use this guide for full interactive browser automation (form
  submission, multi-step flows, authenticated sessions). Those belong in a
  workflow that talks to `jido_browser` directly. See
  [Skill, Workflow, And Subagent Tools](skill-workflow-subagent-tools.md).

## Prerequisites

- A working Jidoka DSL agent. See [Getting Started](getting-started.md).
- `:jido_browser` resolved through `mix deps.get`.
- The `agent-browser` binary installed locally. `jido_browser` ships a Mix
  task to install it:

```bash
mix jido_browser.install
```

- Optional: a custom DNS resolver if you need to test allowlisting behaviour
  in CI. See the browser runtime `:dns_resolver` option.

## Quick Example

A minimal browsing agent uses one DSL block and zero hand-written actions.

```elixir
defmodule MyApp.DocsAgent do
  use Jidoka.Agent

  agent :docs_agent do
    model "openai:gpt-4o-mini"
    instructions "Use search_web and read_page to answer documentation questions."
  end

  tools do
    browser :public_web,
      mode: :read_only,
      allow: ["https://hexdocs.pm", "https://elixir-lang.org"]
  end
end
```

That spec exposes three operations: `search_web`, `read_page`, and
`snapshot_url`. Each operation carries `metadata.source = "browser"` plus the
mode and allowlist that the runtime enforces.

## Concepts

```diagram
╭───────────────────────────╮     ╭──────────────────────────╮
│ tools do                  │────▶│ Jidoka.Browser           │
│   browser :public_web,    │     │  tool_modules/1          │
│     mode: :read_only      │     ╰──────────┬───────────────╯
╰───────────────────────────╯                │ expand mode
                                              ▼
              ╭──────────────────────────────────────────╮
              │ Jidoka.Browser.Tools.{SearchWeb,         │
              │                       ReadPage,          │
              │                       SnapshotUrl}       │
              ╰────────────────────┬─────────────────────╯
                                   │ run/2
                                   ▼
              ╭──────────────────────────────────────────╮
              │ Browser runtime policy                   │
              │  validate_public_url + validate_allowlist│
              │  clamp + truncate                        │
              ╰────────────────────┬─────────────────────╯
                                   │ delegate
                                   ▼
              ╭──────────────────────────────────────────╮
              │ Jido.Browser.Actions.{SearchWeb,         │
              │                        ReadPage,         │
              │                        SnapshotUrl}      │
              ╰──────────────────────────────────────────╯
```

Three concepts cover this integration:

1. **Mode selection.** `mode: :search` exposes only `search_web`. `mode:
   :read_only` exposes search plus `read_page` and `snapshot_url`. Both modes
   are read-only; there is no interactive mode in the Jidoka surface.
2. **Tool expansion.** `Jidoka.Browser.tool_modules/1` returns the concrete
   action modules for a mode. The compiler tags each one with the browser
   metadata so controls and trace consumers can target them.
3. **Runtime policy.** The browser runtime enforces public URLs (no
   loopback, no RFC 1918, no link-local), an optional per-operation
   allowlist, content truncation, and search-result clamping.

### Security / Trust Boundaries

- `validate_public_url/1` rejects URLs that are not `http` or `https`, that
  have no host, that point at `localhost`, `127.0.0.1`, `::1`, `*.localhost`,
  private IPv4 (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`), private
  IPv6 (`fc00::/7`, `fe80::/10`, multicast), or that fail DNS resolution.
- `allow:` is a per-operation allowlist stored on `Operation.metadata["allow"]`.
  When non-empty, the runtime rejects any URL whose host is not in the list.
  Hosts and absolute URL prefixes both work; comparison is case-insensitive.
- The agent-browser binary runs locally. Treat it as untrusted code that may
  fetch arbitrary network content; do not give it access to internal hosts by
  punching holes in the allowlist for short-lived debugging.
- Provider credentials never reach browser actions. The runtime context only
  carries the public Jidoka context plus the agent spec, so allowlists can be
  checked against the operation entry without exposing secrets.
- `truncate_content/2` clamps response bodies and `clamp_search_results/1`
  clamps result counts to limits configured under `:jidoka,
  :browser_max_content_chars` and `:browser_max_results`.

## How To

### Step 1: Expose Search Only

Search is the cheapest tool to enable. Most documentation lookups can be
answered by a follow-up `read_page` call on the link the model returned.

```elixir
tools do
  browser :public_web, mode: :search
end
```

This produces one operation, `search_web`, tagged with
`metadata.mode = "search"`.

### Step 2: Expand To Read-Only Browsing With An Allowlist

To allow page reads, switch to `:read_only` and constrain the destinations.

```elixir
tools do
  browser :public_web,
    mode: :read_only,
    allow: [
      "https://hexdocs.pm",
      "https://elixir-lang.org",
      "https://docs.example.com"
    ]
end
```

The allowlist is stored on every browser operation in the agent spec.
The browser runtime reads it back from
`Jidoka.Context.get_runtime(context, :jidoka_spec).operations` at call time.

### Step 3: Clamp Output For Predictable Costs

Document content is unbounded. Bound it at the application config layer so
every browser operation truncates the same way.

```elixir
# config/runtime.exs
config :jidoka,
  browser_max_results: 5,
  browser_max_content_chars: 12_000
```

Per-call values larger than the configured limit are clamped down; smaller
values are honoured. Use this as a hard ceiling, not as a default.

### Step 4: Run A Deterministic Browser Turn

Tests inject both the LLM and the browser action modules. Swap the underlying
Jido browser actions for deterministic doubles through
`:jidoka, :browser_actions`.

```elixir
defmodule FakeSearchWeb do
  def run(_params, _context),
    do: {:ok, %{results: [%{title: "Hex docs", url: "https://hexdocs.pm/req"}]}}
end

Application.put_env(:jidoka, :browser_actions, %{search_web: FakeSearchWeb})

llm = fn _intent, journal, _ctx ->
  llm_calls = Enum.count(journal.results, fn {_id, r} -> r.kind == :llm end)

  case llm_calls do
    0 -> {:ok, %{type: :operation, name: "search_web", arguments: %{"query" => "req"}}}
    1 -> {:ok, %{type: :final, content: "Try hexdocs.pm/req."}}
  end
end

{:ok, result} = Jidoka.turn(MyApp.DocsAgent, "Where are Req docs?", llm: llm)
```

### Step 5: Inspect The Compiled Operations

The spec metadata makes runtime behaviour visible without running a turn.

```elixir
spec = MyApp.DocsAgent.spec()

Enum.map(spec.operations, & &1.name)
#=> ["search_web", "read_page", "snapshot_url"]

spec.metadata["tool_sources"]
#=> [%{"source" => "browser", "name" => "public_web", "mode" => "read_only",
#      "allow" => ["https://hexdocs.pm", ...]}]
```

## Common Patterns

- **Default to `:search`.** Only expand to `:read_only` when an agent really
  needs page contents; search results plus the user's question are often
  enough.
- **Keep the allowlist explicit.** Empty `allow:` lets the model browse any
  public host. Production agents almost always want a curated list.
- **Use separate browser entities per allowlist.** Two `browser` entries with
  distinct `name:` values give you per-surface allowlists and let controls
  target one specifically.
- **Pair with a control on `read_page`.** When budgets matter, gate
  `read_page` with `operation MyBudgetControl, when: [source: "browser", name: "read_page"]`.

## Testing

The browser test suite is the canonical reference for deterministic doubles.
See `test/jidoka/browser_test.exs` for the full
pattern. The minimum a test needs is:

```elixir
defmodule MyApp.DocsAgentTest do
  use ExUnit.Case, async: false

  setup do
    previous_actions = Application.get_env(:jidoka, :browser_actions)

    Application.put_env(:jidoka, :browser_actions, %{
      search_web: FakeSearchWeb,
      read_page: FakeReadPage,
      snapshot_url: FakeReadPage
    })

    on_exit(fn ->
      if previous_actions do
        Application.put_env(:jidoka, :browser_actions, previous_actions)
      else
        Application.delete_env(:jidoka, :browser_actions)
      end
    end)

    :ok
  end

  test "browser turn calls search_web through a fake" do
    llm = fn _intent, _journal, _ctx ->
      {:ok, %{type: :final, content: "Try hexdocs."}}
    end

    assert {:ok, _result} = Jidoka.turn(MyApp.DocsAgent, "ping", llm: llm)
  end
end
```

The DNS resolver can also be replaced through `:jidoka, :dns_resolver` so
allowlist tests do not hit the network.

## Troubleshooting

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `{:error, %Jidoka.Error.ValidationError{details: %{reason: :invalid_url}}}` | The URL is not http(s), points at a private/loopback host, or failed DNS. | Pass a public URL, or update the DNS resolver fixture in tests. |
| `{:error, %Jidoka.Error.ValidationError{details: %{reason: :browser_url_not_allowed}}}` | The URL host is not in the configured `allow:` list. | Add the host (or a full URL prefix) to the allowlist for the operation. |
| `{:error, %Jidoka.Error.ExecutionError{phase: :browser, details: %{reason: :missing_browser_action}}}` | The underlying `Jido.Browser.Actions.*` module is not loaded. | Install with `mix jido_browser.install` or set `:jidoka, :browser_actions` to override. |
| `ArgumentError: browser mode must be :search or :read_only` | The DSL was passed an unsupported mode. | Use `:search` or `:read_only`. There is no interactive surface. |
| Search returns more results than expected | Per-call `max_results` exceeded the configured ceiling. | Lower `:jidoka, :browser_max_results` or set the call argument explicitly. |

## Reference

Key modules touched in this guide:

- [`Jidoka.Browser`](`Jidoka.Browser`) - mode normalization and tool module
  expansion.
- Browser runtime policy - public-URL
  validation, allowlist enforcement, content truncation, and clamps.
- Tool DSL section - DSL
  schema for the `browser` entity (`mode`, `allow`, `description`,
  `idempotency`, `metadata`).
- [`Jido.Browser`](`Jido.Browser`) - the underlying browser API.

## Related Guides

- [Getting Started](getting-started.md) - the smallest DSL agent end to end.
- [AshJido Resources](ash-jido.md) - a sibling data-backed tool source.
- [MCP Tools](mcp-tools.md) - a sibling tool source for remote MCP servers.
- [Controls](controls.md) - how to gate `read_page` with approvals or
  budgets.
- [Configuration](configuration.md) - where the `browser_max_*` knobs live.
