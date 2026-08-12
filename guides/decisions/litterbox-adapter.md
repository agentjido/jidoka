# LitterBox Adapter Decision

Status: reject for now

Decision date: 2026-08-12

## Decision

Jidoka will not add LitterBox as a core dependency. `jido_cli` will not add it
as a dependency. Jidoka will also not publish a LitterBox adapter from either
repository at this time.

LitterBox is a useful candidate for a future optional adapter package. The
future package can use a name such as `jidoka_litter_box`. It must depend on one
reviewed full commit SHA or on a maintained fork. It must use only public
LitterBox APIs. LitterBox types must not occur in Jidoka public data or durable
session data.

The present decision is a rejection because required evidence and lifecycle
semantics are missing. It is not a rejection of the provider-neutral design.

## Assessed source

The assessment used this exact checkout:

| Item | Value |
| --- | --- |
| Repository | `https://github.com/zblanco/litter_box.git` |
| Commit | `2b9ac96da48e0c2eb46c7558a04d025abc09c4e8` |
| Commit date | 2026-06-19 |
| Package version | `0.1.0` |
| Tags | None |
| README status | Operational but in active development |
| Package license claim | MIT |
| License file in the checkout | Missing |

The package metadata does not include a `LICENSE` file in its package file
list. A future dependency review must not use the package license claim as the
only license evidence.

## Verification result

After `mix deps.get`, these deterministic upstream tests passed:

```text
mix test test/litter_box_test.exs test/docker_workspace_seeding_test.exs
68 tests, 0 failures
```

`mix compile --warnings-as-errors` failed. LitterBox has a warning in the
Sprites backend. Some locked dependencies also have compiler warnings. This
means the candidate does not meet the Jidoka warning-free build rule.

No live Docker, gVisor, Vmsan, Sprites, or remote-provider test ran in this
assessment. The result does not prove a live isolation or network boundary.
The optional Jidoka integration test uses the deterministic `:just_bash`
backend only. That backend is useful for contract tests. It is not a security
boundary.

## Locked dependency graph

The direct dependencies at the assessed commit are:

| Dependency | Constraint | Locked version | Use |
| --- | --- | --- | --- |
| Jason | `~> 1.2` | `1.4.5` | JSON |
| Req | `~> 0.6` | `0.6.1` | HTTP |
| JustBash | `~> 0.3`, optional | `0.3.0` | In-process Bash test and development backend |
| Lua | `~> 1.0.0-rc.3`, optional | `1.0.0-rc.3` | In-process Lua backend |

The locked transitive set is Earmark `1.4.49`, Finch `0.22.0`, HPAX `1.0.3`,
MIME `2.0.7`, Mint `1.9.0`, NimbleOptions `1.1.1`, NimbleParsec `1.4.2`,
NimblePool `1.1.0`, and Telemetry `1.4.2`.

The dependency fetch reported these security conditions:

- Earmark `1.4.49` is retired and has medium advisory
  `EEF-CVE-2026-48591`.
- HPAX `1.0.3` has high advisory `EEF-CVE-2026-58226`.
- Mint `1.9.0` has high advisories `EEF-CVE-2026-58229` and
  `EEF-CVE-2026-56810`. It also has medium advisories
  `EEF-CVE-2026-59249` and `EEF-CVE-2026-59246`.

A future adapter must use a reviewed graph that removes or accepts these risks
through the normal security process.

## Lifecycle mapping

The table maps the Jidoka port to the assessed LitterBox public facade.

| Jidoka callback | LitterBox API | Status | Required adapter rule |
| --- | --- | --- | --- |
| `open` | `LitterBox.open_session/3` | Mapped | Resolve only a trusted host profile. Store no LitterBox session in durable data. |
| `acquire` | `LitterBox.acquire_session/3` or a host registry lookup | Conditional | Return a transient handle. Do not treat a durable binding as a live session. |
| `checkpoint` | `LitterBox.checkpoint/3` | Conditional | Check `capabilities.checkpoints?`. Map exact preservation facts. |
| `restore` | `LitterBox.restore/3` | Conditional | Accept that restore can replace session identity. Return a new Jidoka binding when it does. |
| `fork` | None | Unsupported | Fail closed. Do not claim fork from checkpoint and restore without a proved independent clone. |
| `close` | `LitterBox.release_session/2` or `close_session/2` | Partial | Release active use. Current direct release closes the session. Pool and direct modes have different semantics. |
| `cleanup` | No separate session cleanup API | Unsafe | `destroy/2` accepts an instance, not a durable session binding. A future adapter needs idempotent cleanup evidence. |

Docker checkpoint and restore preserve files, not running processes, services,
or open network state. Vmsan restore can replace the session. Provider restore
semantics can differ. The adapter must keep these differences in confirmed
evidence.

## Enforcement evidence mapping

| Required fact | Assessed status | Reason |
| --- | --- | --- |
| Backend identity | Confirmed | Public results and capabilities include the backend. |
| Minimum isolation | Conditional | Capability data reports isolation. In-process backends are not strong isolation. Docker is container isolation, not a VM. |
| Disabled network | Conditional | Docker can use disabled networking. The adapter still needs a live conformance test. |
| Restricted egress | Conditional | Docker support is narrow and has host and protocol limits. Unsupported forms must fail closed. |
| Workspace mode | Confirmed as a mode | Public profiles and capabilities report the mode. Enforcement still depends on the backend. |
| Immutable image digest | Unavailable | Docker results report a configured image string, not a verified immutable digest. |
| Applied resource limits | Incomplete | Profiles accept limits, but the result does not give one complete normalized proof of all applied limits. |
| Checkpoint support | Conditional | Capabilities report support. Preservation differs by backend. |
| Fork support | Unavailable | There is no native public fork API. |
| Cancellation propagation | Unproved | Timeouts and owner cleanup exist, but this assessment did not prove the Jidoka cancellation-token contract for each capability. |
| Close result | Partial | Close returns success or an error, but backend cleanup details can be hidden. |
| Idempotent cleanup result | Unavailable | There is no separate session cleanup contract with stable evidence. |

Missing evidence must map to `unknown`, `unsupported`, or an error. A profile
request is not enforcement evidence.

## Security findings

LitterBox profiles accept `backend_options`, images, environment values,
workspace host roots, resource options, and backend selection. Docker options
can disable security defaults. These values must come only from trusted host
configuration. Agent, scenario, suite, and extension data can select only a
profile ID.

The Docker copy-in workspace code changes copied files to mode `0777`. A future
adapter must not copy secrets through this path. It must define ownership and
permission rules before it supports host workspace seeding.

LitterBox session handles contain local authority and registry state. They do
not form a portable durable Jidoka binding. A future adapter can persist only a
Jidoka-owned opaque string reference, profile identity, revision, checkpoint,
and confirmed evidence digest. It must keep the live LitterBox session in
transient host runtime state.

The adapter must remove provider-private metadata, host paths, commands,
credentials, environment values, and raw backend options from public evidence.

## Conditions for a new decision

Reassess LitterBox only after all these conditions are true:

1. The source has a reviewed release tag or a maintained fork with one full
   commit pin.
2. License text is present and the package includes it.
3. The locked dependency graph passes the security review.
4. The package compiles without warnings under the supported Elixir and OTP
   versions.
5. A separate optional adapter package implements the Jidoka port. Core Jidoka
   and `jido_cli` still have no LitterBox dependency.
6. Strict profiles get a verified image digest and complete applied-limit
   evidence, or they fail closed.
7. Close and cleanup have separate, idempotent, observable semantics.
8. Raw profile controls cannot enter through imported data.
9. Durable state contains no LitterBox struct, authority, process, port,
   function, credential, or host path.
10. Fork stays unsupported until a backend proves an independent immutable
    clone.
11. Deterministic fake-transport tests and opt-in live backend tests pass.

## Update review policy

Never depend on `main` or another moving Git reference. For each proposed
update, review the full diff from the old SHA to the new SHA. Re-run the
dependency and license audit, the Jidoka adapter conformance suite, the
warning-free compile, and all enabled live backend tests. Record the new SHA
and the test environment in the adapter repository.

Until the conditions above are met, the provider-neutral contracts in
`Jidoka.ExecutionEnvironment` remain the only integration boundary.
