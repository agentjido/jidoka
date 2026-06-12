# Jidoka

Jidoka is a local-first, OTP-native runtime for durable coding sessions on top
of Jido.

It owns the session loop around a coding task:

1. open a workspace session
2. submit a run
3. execute one or more attempts
4. verify the result
5. let an operator approve, retry, reject, or cancel
6. keep typed snapshots, events, artifacts, and outcomes

The core runtime is headless. The CLI and IEx helpers are thin entrypoints over
the public `Jidoka` and `Jidoka.Agent` APIs.

## Installation

```elixir
def deps do
  [
    {:jidoka, "~> 0.1"}
  ]
end
```

## CLI

Build the escript:

```sh
mix escript.build
```

Run the deterministic MVP fixture corpus:

```sh
./jidoka eval-mvp
```

Send a prompt through the Jido AI coding adapter:

```sh
export OPENAI_API_KEY="..."
./jidoka prompt "summarize the current repo state"
```

Or choose a model explicitly:

```sh
export JIDOKA_MODEL="openai:gpt-4.1-mini"
./jidoka prompt "explain the last failing test"
```

By default, prompt execution runs with read-only workspace tools:
`list_files`, `read_file`, `grep`, `git_status`, and `git_diff`.

Set `JIDOKA_PERMISSION_MODE=workspace_write` to enable controlled mutation and
project-check tools: `write_file`, `edit_file`, `mix_test`, and `mix_check`.
Jidoka does not expose an arbitrary shell tool in this mode.

```sh
JIDOKA_PERMISSION_MODE=workspace_write ./jidoka prompt "fix the focused test"
```

## Runtime API

```elixir
{:ok, session} = Jidoka.start_session(id: "repo-main", cwd: File.cwd!())

{:ok, %{run: run}} =
  Jidoka.submit(session, "inspect the failing tests",
    verification_adapter: Jidoka.Verifier.NoopAdapter
  )

{:ok, snapshot} = Jidoka.run_snapshot(session, run.id)

case snapshot.run.status do
  :awaiting_approval -> :ok = Jidoka.approve(session, run.id)
  :failed -> :ok = Jidoka.retry(session, run.id)
  _status -> :ok
end

{:ok, latest} = Jidoka.snapshot_session(session)
:ok = Jidoka.close_session(session)
```

For interactive IEx use:

```elixir
iex -S mix

{:ok, ref} = Jidoka.IEx.open(id: "repo-main", cwd: File.cwd!())
{:ok, sub} = Jidoka.IEx.watch(ref)
{:ok, %{run: run}} = Jidoka.IEx.submit(ref, "inspect the failing tests")
{:ok, run_snap} = Jidoka.IEx.run_snapshot(ref, run.id)
{:ok, snap} = Jidoka.IEx.snapshot(ref)
flush()
:ok = Jidoka.IEx.unwatch(sub)
```

## MVP Evaluation Harness

Run the fixture corpus with:

```sh
mix eval_mvp
```

The command loads `priv/fixtures/mvp_012_fixtures.exs`, drives each scenario
through the public facade, and prints one compact outcome line per scenario.

Each line includes:

- `scenario`: fixture id
- `status`: final run status
- `outcome`: final run outcome
- `attempts`: number of attempts recorded for the run
- `verification`: latest verification status
- `artifact_refs`: artifact ids attached to the run
- `artifacts`: number of artifact records in the snapshot
- `steps`: operator actions the fixture executed, in order

## Scope

Jidoka 0.1 is intentionally focused on the durable single-operator coding loop.
It is not a generic multi-agent orchestration platform, merge engine, policy
marketplace, or Phoenix UI framework.

See `guides/concepts.md` for the core runtime model.
