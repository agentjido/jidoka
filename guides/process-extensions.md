# Process Extensions

Jidoka process extensions use JSON-RPC 2.0 protocol version 1. One child stdout
line contains one complete UTF-8 JSON object. The line limit is 1 MiB. Child
stderr is diagnostic data for the host. The host never copies protocol stdout
to CLI stdout.

## State Machine

The host starts in `new`, sends `initialize`, and accepts no other capability
before a valid response. The response must match the resolved extension ID,
pinned SHA-256 identity, exact permission grant, protocol version, and a subset
of declared capabilities. It then enters `ready`. `shutdown` moves it to
`closed`. A version, identity, grant, or capability mismatch fails closed.

Each request has a unique string or integer ID. A response removes one pending
ID. Duplicate IDs, unsolicited responses, late responses after timeout, and
ambiguous result/error objects are protocol errors. A cancellation notification
uses `request.cancel` with the target ID. A response that wins before cancel is
the terminal result. A timeout removes correlation state, so a late response is
unsolicited. Shutdown has a bounded acknowledgment time; the process host can
force termination after that time.

## Methods

| Group | Methods | Required grant |
| --- | --- | --- |
| Core | `initialize`, `health`, `request.cancel`, `shutdown` | none |
| Tools | `tool.list`, `tool.call` | `tools` and `protocol.tool` |
| Commands | `command.list`, `command.call` | `tools` and `protocol.command` |
| Providers | `provider.list`, `provider.start`, `provider.update`, `provider.cancel` | `providers` and `protocol.provider` |
| Policy | `policy.advise` | `policy_advice` and `protocol.policy` |
| Context | `context.contribute` | `context` and `protocol.context` |
| Lifecycle | `lifecycle.notify` | `protocol.lifecycle` |
| State | `state.restore`, `state.checkpoint` | `state` and `protocol.state` |
| Results | `result.update` | `results` and `protocol.result` |
| UI data | `ui_data.update` | `ui_data` and `protocol.ui_data` |

Methods not in this table are invalid. Only lifecycle, provider update, result,
UI-data, request-cancel methods can be notifications. Tools, commands,
providers, context, state, result, and UI values use portable public data.
Credential-like keys, live values, malformed JSON, extra protocol noise, and
oversized frames fail closed.

JSON-RPC errors use normal integer codes and a string message. Host timeouts and
cancellation are local terminal evidence even if no child error arrives.
Protocol-v1 readers can ignore new optional object fields, but they must reject
new methods, changed required fields, and another protocol version. A breaking
wire change needs protocol version 2.

The process command, environment, working directory, and OS limits are not wire
data. They stay in trusted host configuration. Agent documents cannot supply
them. This protocol does not define TCP, WebSocket, MCP, executable UI, package
installation, or hot reload.

## Process Host

`Jidoka.Extension.ProcessHost` accepts only a resolved process binding and a
trusted descriptor. The descriptor supplies an injected transport. Jidoka has
no direct host-process fallback. Automation startup requires confirmed
constrained-launch evidence. Interactive host launch without this evidence
requires the separate `host_process` grant.

The host captures transport stdout as private protocol frames. It sends stderr
and other diagnostics only through a redacted diagnostic projection. After the
pinned handshake, the verified manifest becomes normal built-in host slots.
Tools compile through `Jidoka.Operation.Source`; the authoritative policy gate
runs before a `tool.call` frame can reach the child. Providers use the normal
model effect path. Commands are host callbacks and must be called only from an
authoritative command effect path.

State restore happens after initialize. State checkpoint, lifecycle events,
context, policy advice, results, and portable UI data use their protocol-v1
methods and registered namespace. A tool, command, or provider not in the
verified manifest is rejected before transport.

The handshake normalizes the manifest once. Tool, command, and provider names
must be non-empty and unique after normalization. Context and policy-advice
flags must be Boolean values. Tool idempotency must be `pure`, `idempotent`,
`dedupe`, `reconcile`, or `unsafe_once`. Tool input policy and initial state,
result, and UI data must be safe maps. Protocol-v1 ignores unknown safe
manifest fields. It rejects unsafe unknown fields.

The process host monitors the active caller. Caller cancellation, timeout,
child exit, malformed protocol, broken transport, and shutdown failure become
stable extension errors. Cancellation sends the transport cancel operation.
Close always attempts transport cleanup. The live handle remains in the host
process and never enters a session, snapshot, event, result, or diagnostic map.
