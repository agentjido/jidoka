# Jidoka Examples

These examples follow the same teaching order as the README: start with one
agent, then add sessions, context, typed results, actions, controls, debugging,
schedules, workflows, delegation, and portability.

The scripts are provider-free by default. They exercise Jidoka contracts,
runtime descriptors, deterministic actions, controls, schedules, traces, and
imported specs without requiring a live model key.

Run them from the package root:

```bash
mix run examples/01_first_agent.exs
mix run examples/02_context_and_results.exs
mix run examples/03_actions_controls_credentials.exs
mix run examples/04_debugging_and_tracing.exs
mix run examples/05_workflows_and_schedules.exs
mix run examples/06_delegation_and_imports.exs
```

## Teaching Order

1. `01_first_agent.exs` covers agents, chat targets, and sessions.
2. `02_context_and_results.exs` covers runtime context and typed results.
3. `03_actions_controls_credentials.exs` covers actions, controls,
   human-in-the-loop approvals, and credential references.
4. `04_debugging_and_tracing.exs` covers request inspection and structured
   traces without a provider call.
5. `05_workflows_and_schedules.exs` covers deterministic workflows and manual
   schedule execution.
6. `06_delegation_and_imports.exs` covers subagent/tool portability boundaries
   and constrained imported specs.

The later guide and Livebook layers should reuse this order instead of
inventing a separate progression.

## Example Constraints

Keep this tree intentionally small until the V3 DSL is stable:

- one feature group per script
- no example-specific modules under `lib/`
- no shared demo framework, registry, or mix task until repeated code proves it
  is worth extracting
- no live provider calls in default examples
- no fixture trees unless the example cannot explain the feature with inline
  data
- prefer one deterministic assertion path over a polished CLI

When an example needs more than a small script, move the extra explanation to a
guide or Livebook rather than growing a second application inside `examples/`.
