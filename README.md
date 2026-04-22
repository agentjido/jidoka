# Jidoka

Jidoka is a headless coding-session runtime with a small public facade.

`Jidoka.Agent` is the primary public API.
`Jidoka` only exposes session lifecycle helpers.

## Example

```elixir
{:ok, session_ref} = Jidoka.start_session(id: "repo-main", cwd: "/path/to/repo")

{:ok, request} = Jidoka.Agent.ask(session_ref, "inspect the failing tests")
{:ok, _result} = Jidoka.Agent.await(session_ref, request.id)

{:ok, branch_id} = Jidoka.Agent.branch(session_ref, label: "before-refactor")
{:ok, snapshot} = Jidoka.Agent.navigate(session_ref, branch_id)

{:ok, latest} = Jidoka.Agent.snapshot(session_ref)
:ok = Jidoka.close_session(session_ref)
```

## IEx

For the first interactive shell, use `iex -S mix` and the thin helper module:

```elixir
iex -S mix

{:ok, ref} = Jidoka.IEx.open(id: "repo-main", cwd: File.cwd!())
{:ok, sub} = Jidoka.IEx.watch(ref)
{:ok, req} = Jidoka.IEx.ask(ref, "inspect the failing tests")
{:ok, snap} = Jidoka.IEx.snapshot(ref)
flush()
:ok = Jidoka.IEx.unwatch(sub)
```

## MVP Evaluation Harness

Run the fixture corpus for ST-MVP-012 with:

```sh
mix eval_mvp
```

Or build the escript and run the same command through `jidoka`:

```sh
mix escript.build
./jidoka eval-mvp
```

You can also send a direct prompt through the CLI:

```sh
export OPENAI_API_KEY="..."
./jidoka prompt "summarize the current repo state"
```

If you want to pick the exact model explicitly, set `JIDOKA_MODEL` instead:

```sh
export JIDOKA_MODEL="openai:gpt-4.1-mini"
./jidoka prompt "explain the last failing test"
```

The prompt command boots a minimal `Jido.AI.Agent`, streams runtime activity to
the terminal, auto-approves the passed verification step, and prints the final
response. Prompt reports are written into the temporary CLI workspace under
`$TMPDIR/jidoka-cli`.

By default, `jidoka prompt` runs with read-only workspace tools enabled:
`list_files`, `read_file`, `grep`, and `git_status`. The active workspace is the
directory where you invoke the command. Permission mode defaults to `read_only`
and can be set with `JIDOKA_PERMISSION_MODE`.

The command loads `priv/fixtures/mvp_012_fixtures.exs`, runs each scenario through
the public `Jidoka` facade, and prints a compact outcome line per scenario.

Each line includes:

- `scenario`: fixture id
- `status`: final run status
- `outcome`: final run outcome
- `attempts`: number of attempts recorded for the run
- `verification`: latest verification status
- `artifact_refs`: artifact ids attached to the run
- `artifacts`: number of artifact records in the snapshot
- `steps`: operator actions the fixture executed, in order

Output example:

```text
scenario=passing_task | status=completed | outcome=:approved | attempts=1 | verification=:passed | artifact_refs=[] | artifacts=0 | steps=  :approve
```

## Design Notes

- external commands are normalized into canonical signals
- the runtime emits signals and keeps a stable snapshot API for adapters
- `Jido.Thread` is the audit log conceptually, while authoritative state is runtime metadata plus durable history
