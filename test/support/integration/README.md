# Integration Support

Shared modules for `test/integration` live here, grouped by role:

- `actions/` - test `Jidoka.Action` modules used by integration agents.
- `agents/` - test `Jidoka.Agent` modules used by integration scenarios.
- `controls/` - test controls used by controls integration tests.

Keep scenario assertions in `test/integration`; keep reusable support modules here.

Guide-backed examples:

- `MinimalChatAgent` supports the minimal DSL examples.
- `AccountAgent` and `AccountLookupAction` support the one-tool loop examples.
- `ControlledLookupAgent` and `controls/*` support controls and approval
  examples.
- Operation-source, memory, observability, and structured-result examples use
  local specs in their integration tests when a reusable DSL module would hide
  the point of the example.
