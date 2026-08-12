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
