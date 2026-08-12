# Extension Architecture

Jidoka extensions use two separate trust domains.

Agent YAML and JSON contain only ordered `Jidoka.Extension.Request` data. A
request has an ID and bounded JSON configuration. It cannot name a module,
function, process, command, image, mount, or network rule.

The embedding host supplies a trusted registry. Each portable
`Jidoka.Extension.Registration` records a pinned identity, source class,
release, SHA-256 content hash, trust state, permissions, capabilities,
supported modes, and protocol version. Live built-in factories and process
descriptors stay in the injected registry. They are not part of the portable
registration.

`Jidoka.Extension.Resolver` fails before session start when a record is
unknown, duplicated, disabled, untrusted, unpinned, incompatible with the run
mode, outside the host permission allowance, or invalid for its configuration
schema. A successful resolution gives a portable `Binding`. The binding is the
durable identity for resume and fork. Resume fails if the code identity,
permission grant, capability set, mode, or protocol version changed.

This contract does not install or start extensions. Later host layers consume
the binding and keep all live runtime values outside durable data.

## Lifecycle Events

`Jidoka.Extension.Event` is separate from the interactive `Jidoka.Event`
stream contract. Its version-1 catalog is fixed:

- `session.start`, `session.resume`, `session.compact`, and `session.end`
- `turn.start`, `turn.update`, and `turn.end`
- `model.start`, `model.update`, `model.end`, and `model.error`
- `tool.before`, `tool.update`, `tool.after`, and `tool.error`
- `automation.cell.start` and `automation.cell.end`

For one session, the dispatcher delivers events in call order. A normal turn
has one start, zero or more updates, paired model and tool events, and one turn
end. Cancellation, hibernation, policy denial, and runtime failure also use one
turn end with the reason in portable data. A sequence has one session start and
one session end around its turn events.

Payloads use string keys, have a 64 KiB limit, and remove credential-like
fields before delivery. IDs and time can be injected for repeatable tests.
Each subscriber has a time limit. A raise, exit, timeout, or bad return becomes
delivery evidence. It does not change the turn result and does not stop the
next subscriber. Events do not write to CLI output and do not create a second
event store.
