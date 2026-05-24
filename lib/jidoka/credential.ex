defmodule Jidoka.Credential do
  @moduledoc """
  Credential-reference boundary for authenticated agent operations.

  Jidoka V3 ships credential brokering as a reference contract, not as a
  built-in secret broker. Agents, controls, traces, and tool metadata may carry
  references to a credential, connection, account, or lease. They must not carry
  raw credential values.

  The application or integration layer remains responsible for exchanging a
  reference for a real secret at execution time. That keeps Jidoka useful as the
  agent authoring layer while leaving vault lookup, OAuth refresh, tenant
  routing, and outbound request signing inside the system that owns those
  security guarantees.
  """
end
