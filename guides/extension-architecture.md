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
