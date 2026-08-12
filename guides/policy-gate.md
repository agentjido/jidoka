# Host policy gate

Jidoka checks protected external effects before it calls their capabilities.
The host policy is authoritative. Agent metadata and extension advice cannot
override a host denial.

## Enforcement order

For an operation, Jidoka uses this order:

1. Record the effect intent.
2. Apply operation controls and existing approval rules.
3. Build a portable `Jidoka.Policy.Request`.
4. Call the host policy capability.
5. Record the `Jidoka.Policy.Decision` in the effect journal.
6. Call the operation capability only after an allow decision or an approved
   review decision.
7. Record the effect result.

The same policy decision is used after a durable review resume. A completed
effect replay does not call the policy or the external capability again.

## Defaults and fail-closed behavior

The built-in policy permits normal model and operation effects. This keeps the
current Jidoka facade compatible for applications that do not install a custom
policy. The built-in policy denies execution-environment and process-extension
effects. A host must install an explicit policy before those effect classes can
run.

A missing capability, exception, exit, timeout, malformed response, or denial
stops the protected effect. The protected capability is not called.

```elixir
policy = fn request, _context ->
  if request.effect_class == :operation and request.action == "weather" do
    {:ok,
     Jidoka.Policy.Decision.new!(
       outcome: :allow,
       rule_id: "host.weather.read"
     )}
  else
    {:ok,
     Jidoka.Policy.Decision.new!(
       outcome: :deny,
       rule_id: "host.default.deny"
     )}
  end
end

Jidoka.chat(spec, "Weather?", policy: policy)
```

Policy requests and decisions are portable data. They reject functions,
process identifiers, ports, and references in resource, advice, reason, and
evidence fields. Do not put credentials or raw provider handles in these
fields.
