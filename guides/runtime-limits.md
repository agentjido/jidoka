# Runtime Limits

Jidoka can apply one portable set of limits to an ordered session sequence.
The limits reduce the agent plan. They do not increase agent controls.

```elixir
{:ok, result} =
  Jidoka.Session.run_sequence(session, requests,
    runtime_limits: %{
      max_model_turns: 4,
      turn_timeout_ms: 30_000,
      capability_timeout_ms: 5_000,
      sequence_timeout_ms: 120_000,
      max_total_tokens: 20_000,
      max_total_cost: 2.0
    }
  )

result.limits.applied
result.limits.observed
result.limits.exceeded
```

## Contract

`Jidoka.Runtime.Limits.Applied` contains the limits that Jidoka used.
`Jidoka.Runtime.Limits.Observed` contains completed user-turn, model-step,
tool-call-group, and tool-call counts plus sequence duration, normalized usage,
and environment facts. `model_turns` remains an equal compatibility alias for
`model_steps`. `Jidoka.Runtime.Limits.Exceeded`
identifies the limit that stopped work. `Jidoka.Runtime.Limits.Evidence` keeps
these values together on `Jidoka.Session.Sequence.Result.limits`.

| Field | Meaning |
| --- | --- |
| `max_model_turns` | Compatibility name for the maximum model steps in one user turn. |
| `turn_timeout_ms` | Maximum wall time for one turn. |
| `capability_timeout_ms` | Maximum wall time for one model, tool, extension, or environment call. |
| `sequence_timeout_ms` | Maximum wall time for the ordered sequence. |
| `max_total_tokens` | Maximum observed normalized tokens for completed turns. |
| `max_total_cost` | Maximum observed normalized provider cost for completed turns. |
| `environment` | Portable resource-limit facts supplied by the trusted host. |

All integer limits must be positive. Cost must be greater than zero. Unknown
keys fail validation. The runtime uses the lower value when the agent plan has
a lower model-turn or turn-time limit.

## Stop Rules

A capability deadline stops its worker. A request cancellation also stops
registered model, tool, extension, and environment workers. Jidoka checks the
sequence deadline before it starts a new turn. It checks cumulative usage after
each completed turn. Thus, a turn that crosses a usage limit remains in the
completed prefix, and Jidoka does not start the next turn.

A synchronous sequence returns a normal typed sequence result with status
`error` when a runtime limit stops it. The terminal reason and `limits` evidence
show the cause. An asynchronous caller can still cancel the public sequence
request through `Jidoka.cancel/2`.

## Clocks And Tests

Use the injected `:clock` function for deterministic sequence and turn time
tests. Use short fake capability delays only when a test must prove that Jidoka
kills a blocked worker. Do not use provider calls in limit tests.

Jidoka reports provider usage. It does not look up prices. A provider that does
not report a usage fact cannot contribute that fact to a budget.

Logical counts do not include provider transport retries. A parallel group of
three calls adds one tool-call group and three tool calls. Two dependent calls
requested by two model steps add two groups and two calls.
