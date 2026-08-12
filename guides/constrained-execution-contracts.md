# Constrained-execution contracts

Jidoka keeps execution selection, trusted policy, durable identity, and
confirmed enforcement in separate provider-neutral contracts.

## Requested policy

`Jidoka.ExecutionEnvironment.PolicyRequest` is the only contract that untrusted
agent, scenario, or suite data can create. It contains a trusted profile
identifier and optional capability identifiers. It cannot contain an image,
command, mount, environment variable, network rule, adapter, or backend option.

## Trusted security profile

`Jidoka.ExecutionEnvironment.SecurityProfile` comes from host configuration. It
contains an immutable profile digest, adapter identity, required isolation,
network and workspace rules, applied-limit ceilings, checkpoint and fork
requirements, and a retention rule. Image requirements use an immutable
`sha256:` digest.

## Durable binding and checkpoint

`Jidoka.ExecutionEnvironment.Binding` stores only portable identity. A binding
has an opaque resource reference but no process, client, function, credential,
adapter struct, or raw host path.

`Jidoka.ExecutionEnvironment.Checkpoint` identifies immutable recovery data. It
states what the checkpoint preserves and whether it is safe to fork. It does
not contain a live environment handle.

## Confirmed evidence

`Jidoka.ExecutionEnvironment.EnforcementEvidence` contains facts that an
adapter observed. Its status is `confirmed`, `partial`, `unknown`, or
`unsupported`. Unknown facts stay unknown. Requested profile values are not
copied into confirmed fields.

All contracts have version 1 constructors and stable projections. Projections
use string keys, remove credential-like fields, and encode with Jason. Live
values fail validation with their data path.

## Trusted host resolution

An embedding host creates `Registration` values. Each registration joins one
trusted profile, one installed adapter module, and one provider-neutral adapter
capability declaration. `ProfileResolver.resolve/3` accepts only a
`PolicyRequest`. Agent and scenario documents cannot create registrations.

Before `open`, `Validator.validate_profile/3` checks availability, adapter
identity, isolation, network, workspace, immutable image evidence, limit keys,
checkpoint support, fork support, and requested capability identifiers. After
each lifecycle call, `Validator.validate_evidence/2` checks actual confirmed
facts against every profile requirement. Missing evidence is not confirmation.

Resolution and validation return stable `Jidoka.ExecutionEnvironment.Error`
values. Unknown, disabled, malformed, unavailable, insufficient, and
unenforced profiles fail before protected work continues.

## Lifecycle manager

Adapters implement seven callbacks: `open`, `acquire`, `checkpoint`, `restore`,
`fork`, `close`, and `cleanup`. `Manager` calls the host policy before every
callback and validates confirmed evidence after every successful callback.

`open` creates or locates durable state. `acquire` returns an opaque transient
manager handle and is exclusive for one binding. `checkpoint` produces an
immutable portable checkpoint. `restore` can rotate binding identity. `fork`
uses only a forkable checkpoint and never running mutable state. `close`
releases one transient handle but preserves durable state. `cleanup`
idempotently destroys durable resources.

Use `Manager.with_acquired/4` when possible. It closes the transient handle
after success, error, or exception. The manager also closes its remaining
handles when it stops. Runtime handles never enter bindings, checkpoints,
sessions, or snapshots.

## Durable session use

Pass an `execution_environment` runtime option with a manager, a
`PolicyRequest`, and an `:ephemeral` or `:durable` retention value. Jidoka opens
the environment before it stores a new session. Each active turn acquires one
transient handle. Jidoka closes that handle for success, hibernation, error,
and cancellation.

`Jidoka.Session.Environment` is the portable session value. Session data and
snapshots use schema version 2 and still accept version 1 data without an
environment. Each durable effect checkpoint stores the turn snapshot and the
matching environment checkpoint in one session revision.

Recovery restores the latest immutable environment checkpoint, validates its
confirmed evidence, and then acquires a handle. Session fork asks the manager
to fork the stored checkpoint. It gives the child a different binding and does
not change the source session.

Ephemeral environments are cleaned after a completed, failed, or cancelled
run. They stay available while a session is hibernated. Durable environments
need an explicit trusted cleanup action. Cleaned session state rejects later
acquire, restore, and fork operations.
