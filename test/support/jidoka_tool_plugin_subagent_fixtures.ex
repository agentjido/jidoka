defmodule JidokaTest.AddNumbers do
  use Jidoka.Action,
    description: "Adds two integers together.",
    schema: Zoi.object(%{a: Zoi.integer(), b: Zoi.integer()})

  @impl true
  def run(%{a: a, b: b}, _context) do
    {:ok, %{sum: a + b}}
  end
end

defmodule JidokaTest.MultiplyNumbers do
  use Jidoka.Action,
    description: "Multiplies two integers together.",
    schema: Zoi.object(%{a: Zoi.integer(), b: Zoi.integer()})

  @impl true
  def run(%{a: a, b: b}, _context) do
    {:ok, %{product: a * b}}
  end
end

defmodule JidokaTest.FailingAction do
  use Jidoka.Action,
    description: "Always returns the requested failure reason.",
    schema: Zoi.object(%{reason: Zoi.string()})

  @impl true
  def run(%{reason: reason}, _context), do: {:error, reason}
end

defmodule JidokaTest.ToolAgent do
  use Jidoka.Agent

  agent :tool_agent do
    model :fast
    instructions "You can use math tools."
  end

  tools do
    action(JidokaTest.AddNumbers)
  end
end

defmodule JidokaTest.MathPlugin do
  use Jidoka.Plugin,
    description: "Provides math tools for Jidoka agents.",
    tools: [JidokaTest.MultiplyNumbers]
end

defmodule JidokaTest.PluginAgent do
  use Jidoka.Agent

  agent :plugin_agent do
    model :fast
    instructions "You can use plugin-provided tools."
  end

  tools do
    plugin JidokaTest.MathPlugin
  end
end

defmodule JidokaTest.ApproveDelegationControl do
  use Jidoka.Control, name: "approve_delegation"

  @impl true
  def call(%Jidoka.Guardrails.Tool{operation_kind: kind, tool_name: name, context: context})
      when kind in [:subagent, :handoff] do
    notify_pid = Map.get(context, :notify_pid, Map.get(context, "notify_pid"))

    Jidoka.Approval.request("Approve #{kind} #{name}.",
      data: %{notify_pid: notify_pid, from: :operation_control, kind: kind, name: to_string(name)}
    )
  end

  def call(%Jidoka.Guardrails.Tool{}), do: :ok
end

defmodule JidokaTest.NotifyDelegationInterruptHook do
  use Jidoka.Hook, name: "notify_delegation_interrupt"

  @impl true
  def call(%Jidoka.Hooks.InterruptInput{interrupt: interrupt}) do
    if pid = get_in(interrupt.data, [:notify_pid]) do
      send(pid, {:delegation_interrupt, interrupt.kind, interrupt.data[:kind], interrupt.data[:from]})
    end

    :ok
  end
end

defmodule JidokaTest.ResearchSpecialist do
  defmodule Runtime do
    use Jido.Agent,
      name: "research_specialist_runtime",
      schema: Zoi.object(%{})
  end

  def name, do: "research_agent"
  def runtime_module, do: Runtime
  def start_link(opts \\ []), do: Jidoka.start_agent(Runtime, opts)

  def chat(_pid, message, opts \\ []) do
    context = Keyword.get(opts, :context, %{})

    if notify_pid = Map.get(context, :notify_pid, Map.get(context, "notify_pid")) do
      send(notify_pid, {:research_specialist_context, context})
    end

    tenant = Map.get(context, :tenant, Map.get(context, "tenant", "none"))
    depth = Map.get(context, Jidoka.Subagent.depth_key(), 0)

    {:ok, "research:#{message}:tenant=#{tenant}:depth=#{depth}"}
  end
end

defmodule JidokaTest.ReviewSpecialist do
  defmodule Runtime do
    use Jido.Agent,
      name: "review_specialist_runtime",
      schema: Zoi.object(%{})
  end

  def name, do: "review_agent"
  def runtime_module, do: Runtime
  def start_link(opts \\ []), do: Jidoka.start_agent(Runtime, opts)
  def chat(_pid, message, _opts \\ []), do: {:ok, "review:#{message}"}
end

defmodule JidokaTest.OrchestratorAgent do
  use Jidoka.Agent

  agent :orchestrator_agent do
    model :fast
    instructions "You can delegate to subagents."
  end

  tools do
    subagent JidokaTest.ResearchSpecialist

    subagent JidokaTest.ReviewSpecialist,
      as: "review_specialist",
      description: "Ask the review specialist"
  end
end

defmodule JidokaTest.PeerOrchestratorAgent do
  use Jidoka.Agent

  agent :peer_orchestrator_agent do
    model :fast
    instructions "You can delegate to a peer specialist."
  end

  tools do
    subagent JidokaTest.ResearchSpecialist, target: {:peer, "research-peer-test"}
  end
end

defmodule JidokaTest.ContextPeerOrchestratorAgent do
  use Jidoka.Agent

  agent :context_peer_orchestrator_agent do
    model :fast
    instructions "You can delegate to a context-derived peer specialist."
  end

  tools do
    subagent JidokaTest.ResearchSpecialist, target: {:peer, {:context, :research_peer_id}}
  end
end

defmodule JidokaTest.ContextPeerNoForwardOrchestratorAgent do
  use Jidoka.Agent

  agent :context_peer_no_forward_orchestrator_agent do
    model :fast
    instructions "You can delegate to a context-derived peer without forwarding context."
  end

  tools do
    subagent JidokaTest.ResearchSpecialist,
      target: {:peer, {:context, :research_peer_id}},
      forward_context: :none
  end
end

defmodule JidokaTest.WrongPeerOrchestratorAgent do
  use Jidoka.Agent

  agent :wrong_peer_orchestrator_agent do
    model :fast
    instructions "You expect a research specialist peer."
  end

  tools do
    subagent JidokaTest.ResearchSpecialist, target: {:peer, "wrong-peer-test"}
  end
end

defmodule JidokaTest.ForwardNoneOrchestratorAgent do
  use Jidoka.Agent

  agent :forward_none_orchestrator_agent do
    model :fast
    instructions "You can delegate without public context."
  end

  tools do
    subagent JidokaTest.ResearchSpecialist, forward_context: :none
  end
end

defmodule JidokaTest.ForwardOnlyOrchestratorAgent do
  use Jidoka.Agent

  agent :forward_only_orchestrator_agent do
    model :fast
    instructions "You can delegate with selected context."
  end

  tools do
    subagent JidokaTest.ResearchSpecialist, forward_context: {:only, [:tenant, "notify_pid"]}
  end
end

defmodule JidokaTest.ForwardExceptOrchestratorAgent do
  use Jidoka.Agent

  agent :forward_except_orchestrator_agent do
    model :fast
    instructions "You can delegate with excluded context."
  end

  tools do
    subagent JidokaTest.ResearchSpecialist, forward_context: {:except, ["secret"]}
  end
end

defmodule JidokaTest.StructuredOrchestratorAgent do
  use Jidoka.Agent

  agent :structured_orchestrator_agent do
    model :fast
    instructions "You can delegate with structured metadata."
  end

  tools do
    subagent JidokaTest.ResearchSpecialist, result: :structured
  end
end

defmodule JidokaTest.MapResultSpecialist do
  defmodule Runtime do
    use Jido.Agent,
      name: "map_result_specialist_runtime",
      schema: Zoi.object(%{})
  end

  def name, do: "map_result_agent"
  def runtime_module, do: Runtime
  def start_link(opts \\ []), do: Jidoka.start_agent(Runtime, opts)

  def chat(_pid, message, _opts \\ []) do
    {:ok,
     %{
       category: "research",
       confidence: 0.91,
       summary: "map:#{message}"
     }}
  end
end

defmodule JidokaTest.StructuredMapOrchestratorAgent do
  use Jidoka.Agent

  agent :structured_map_orchestrator_agent do
    model :fast
    instructions "You can delegate to subagents that return structured maps."
  end

  tools do
    subagent JidokaTest.MapResultSpecialist, result: :structured
  end
end

defmodule JidokaTest.ListResultSpecialist do
  defmodule Runtime do
    use Jido.Agent,
      name: "list_result_specialist_runtime",
      schema: Zoi.object(%{})
  end

  def name, do: "list_result_agent"
  def runtime_module, do: Runtime
  def start_link(opts \\ []), do: Jidoka.start_agent(Runtime, opts)
  def chat(_pid, _message, _opts \\ []), do: {:ok, ["not", "supported"]}
end

defmodule JidokaTest.StructuredInvalidResultOrchestratorAgent do
  use Jidoka.Agent

  agent :structured_invalid_result_orchestrator_agent do
    model :fast
    instructions "You reject unsupported structured child result shapes."
  end

  tools do
    subagent JidokaTest.ListResultSpecialist, result: :structured
  end
end

defmodule JidokaTest.ControlledSubagentOrchestratorAgent do
  use Jidoka.Agent

  agent :controlled_subagent_orchestrator_agent do
    model :fast
    instructions "You require approval before delegating to subagents."
  end

  controls do
    operation(JidokaTest.ApproveDelegationControl,
      when: [kind: :subagent]
    )
  end

  tools do
    subagent JidokaTest.ResearchSpecialist
  end
end

defmodule JidokaTest.MissingPeerOrchestratorAgent do
  use Jidoka.Agent

  agent :missing_peer_orchestrator_agent do
    model :fast
    instructions "You expect an existing peer."
  end

  tools do
    subagent JidokaTest.ResearchSpecialist, target: {:peer, "missing-peer-test"}
  end
end

defmodule JidokaTest.SlowSpecialist do
  defmodule Runtime do
    use Jido.Agent,
      name: "slow_specialist_runtime",
      schema: Zoi.object(%{})
  end

  def name, do: "slow_agent"
  def runtime_module, do: Runtime
  def start_link(opts \\ []), do: Jidoka.start_agent(Runtime, opts)

  def chat(_pid, message, _opts \\ []) do
    Process.sleep(100)
    {:ok, "slow:#{message}"}
  end
end

defmodule JidokaTest.TimeoutOrchestratorAgent do
  use Jidoka.Agent

  agent :timeout_orchestrator_agent do
    model :fast
    instructions "You can delegate to a slow specialist."
  end

  tools do
    subagent JidokaTest.SlowSpecialist, timeout: 20
  end
end

defmodule JidokaTest.InvalidResultSpecialist do
  defmodule Runtime do
    use Jido.Agent,
      name: "invalid_result_specialist_runtime",
      schema: Zoi.object(%{})
  end

  def name, do: "invalid_result_agent"
  def runtime_module, do: Runtime
  def start_link(opts \\ []), do: Jidoka.start_agent(Runtime, opts)
  def chat(_pid, _message, _opts \\ []), do: {:ok, %{not: "text"}}
end

defmodule JidokaTest.InvalidResultOrchestratorAgent do
  use Jidoka.Agent

  agent :invalid_result_orchestrator_agent do
    model :fast
    instructions "You can delegate to an invalid specialist."
  end

  tools do
    subagent JidokaTest.InvalidResultSpecialist
  end
end

defmodule JidokaTest.RaisingSpecialist do
  defmodule Runtime do
    use Jido.Agent,
      name: "raising_specialist_runtime",
      schema: Zoi.object(%{})
  end

  def name, do: "raising_agent"
  def runtime_module, do: Runtime
  def start_link(opts \\ []), do: Jidoka.start_agent(Runtime, opts)
  def chat(_pid, _message, _opts \\ []), do: raise("raising specialist failed")
end

defmodule JidokaTest.RaisingOrchestratorAgent do
  use Jidoka.Agent

  agent :raising_orchestrator_agent do
    model :fast
    instructions "You can delegate to a raising specialist."
  end

  tools do
    subagent JidokaTest.RaisingSpecialist
  end
end

defmodule JidokaTest.InterruptSpecialist do
  defmodule Runtime do
    use Jido.Agent,
      name: "interrupt_specialist_runtime",
      schema: Zoi.object(%{})
  end

  def name, do: "interrupt_agent"
  def runtime_module, do: Runtime
  def start_link(opts \\ []), do: Jidoka.start_agent(Runtime, opts)

  def chat(_pid, _message, _opts \\ []) do
    {:interrupt, Jidoka.Interrupt.new(kind: :approval, message: "Need approval")}
  end
end

defmodule JidokaTest.InterruptOrchestratorAgent do
  use Jidoka.Agent

  agent :interrupt_orchestrator_agent do
    model :fast
    instructions "You can delegate to an interrupting specialist."
  end

  tools do
    subagent JidokaTest.InterruptSpecialist
  end
end

defmodule JidokaTest.InvalidInterruptSpecialist do
  defmodule Runtime do
    use Jido.Agent,
      name: "invalid_interrupt_specialist_runtime",
      schema: Zoi.object(%{})
  end

  def name, do: "invalid_interrupt_agent"
  def runtime_module, do: Runtime
  def start_link(opts \\ []), do: Jidoka.start_agent(Runtime, opts)
  def chat(_pid, _message, _opts \\ []), do: {:interrupt, :not_an_interrupt}
end

defmodule JidokaTest.InvalidInterruptOrchestratorAgent do
  use Jidoka.Agent

  agent :invalid_interrupt_orchestrator_agent do
    model :fast
    instructions "You can delegate to an invalid interrupt specialist."
  end

  tools do
    subagent JidokaTest.InvalidInterruptSpecialist
  end
end

defmodule JidokaTest.StartFailureSpecialist do
  defmodule Runtime do
    use Jido.Agent,
      name: "start_failure_specialist_runtime",
      schema: Zoi.object(%{})
  end

  def name, do: "start_failure_agent"
  def runtime_module, do: Runtime
  def start_link(_opts \\ []), do: {:error, :boom}
  def chat(_pid, _message, _opts \\ []), do: {:ok, "unreachable"}
end

defmodule JidokaTest.StartFailureOrchestratorAgent do
  use Jidoka.Agent

  agent :start_failure_orchestrator_agent do
    model :fast
    instructions "You can delegate to a failing specialist."
  end

  tools do
    subagent JidokaTest.StartFailureSpecialist
  end
end

defmodule JidokaTest.StartIgnoreSpecialist do
  defmodule Runtime do
    use Jido.Agent,
      name: "start_ignore_specialist_runtime",
      schema: Zoi.object(%{})
  end

  def name, do: "start_ignore_agent"
  def runtime_module, do: Runtime
  def start_link(_opts \\ []), do: :ignore
  def chat(_pid, _message, _opts \\ []), do: {:ok, "unreachable"}
end

defmodule JidokaTest.StartIgnoreOrchestratorAgent do
  use Jidoka.Agent

  agent :start_ignore_orchestrator_agent do
    model :fast
    instructions "You can delegate to an ignored specialist."
  end

  tools do
    subagent JidokaTest.StartIgnoreSpecialist
  end
end

defmodule JidokaTest.StartTripleSpecialist do
  defmodule Runtime do
    use Jido.Agent,
      name: "start_triple_specialist_runtime",
      schema: Zoi.object(%{})
  end

  def name, do: "start_triple_agent"
  def runtime_module, do: Runtime

  def start_link(opts \\ []) do
    with {:ok, pid} <- Jidoka.start_agent(Runtime, opts) do
      {:ok, pid, %{mode: :triple}}
    end
  end

  def chat(_pid, message, _opts \\ []), do: {:ok, "triple:#{message}"}
end

defmodule JidokaTest.StartTripleOrchestratorAgent do
  use Jidoka.Agent

  agent :start_triple_orchestrator_agent do
    model :fast
    instructions "You can delegate to a triple-start specialist."
  end

  tools do
    subagent JidokaTest.StartTripleSpecialist
  end
end

defmodule JidokaTest.BillingHandoffSpecialist do
  defmodule Runtime do
    use Jido.Agent,
      name: "billing_handoff_specialist_runtime",
      schema: Zoi.object(%{})
  end

  def name, do: "billing_specialist"
  def runtime_module, do: Runtime
  def start_link(opts \\ []), do: Jidoka.start_agent(Runtime, opts)
  def chat(_pid, message, _opts \\ []), do: {:ok, "billing:#{message}"}
end

defmodule JidokaTest.ReviewHandoffSpecialist do
  defmodule Runtime do
    use Jido.Agent,
      name: "review_handoff_specialist_runtime",
      schema: Zoi.object(%{})
  end

  def name, do: "review_specialist"
  def runtime_module, do: Runtime
  def start_link(opts \\ []), do: Jidoka.start_agent(Runtime, opts)
  def chat(_pid, message, _opts \\ []), do: {:ok, "review-handoff:#{message}"}
end

defmodule JidokaTest.HandoffRouterAgent do
  use Jidoka.Agent

  agent :handoff_router_agent do
    model :fast
    instructions "Transfer ownership when a specialist should continue the conversation."

    description "Routes owned support conversations."
  end

  tools do
    handoff(JidokaTest.BillingHandoffSpecialist,
      as: :billing_specialist,
      description: "Transfer billing ownership to the billing specialist."
    )
  end
end

defmodule JidokaTest.SessionBillingHandoffAgent do
  use Jidoka.Agent

  agent :session_billing_handoff_agent do
    model :fast
    instructions "Continue support conversations after billing ownership is transferred."
  end
end

defmodule JidokaTest.SessionHandoffRouterAgent do
  use Jidoka.Agent

  agent :session_handoff_router_agent do
    model :fast
    instructions "Transfer session ownership when billing should continue the conversation."
  end

  tools do
    handoff(JidokaTest.SessionBillingHandoffAgent,
      as: :session_billing_specialist,
      description: "Transfer session ownership to the billing specialist."
    )
  end
end

defmodule JidokaTest.ControlledHandoffRouterAgent do
  use Jidoka.Agent

  agent :controlled_handoff_router_agent do
    model :fast
    instructions "You require approval before transferring conversation ownership."
  end

  controls do
    operation(JidokaTest.ApproveDelegationControl,
      when: [kind: :handoff]
    )
  end

  tools do
    handoff(JidokaTest.SessionBillingHandoffAgent,
      as: :controlled_billing_specialist,
      description: "Transfer to billing after approval."
    )
  end
end

defmodule JidokaTest.HandoffForwardNoneAgent do
  use Jidoka.Agent

  agent :handoff_forward_none_agent do
    model :fast
    instructions "Transfer without public context."
  end

  tools do
    handoff(JidokaTest.BillingHandoffSpecialist,
      as: :billing_specialist,
      forward_context: :none
    )
  end
end

defmodule JidokaTest.HandoffForwardOnlyAgent do
  use Jidoka.Agent

  agent :handoff_forward_only_agent do
    model :fast
    instructions "Transfer selected context."
  end

  tools do
    handoff(JidokaTest.BillingHandoffSpecialist,
      as: :billing_specialist,
      forward_context: {:only, [:tenant, "account_id"]}
    )
  end
end

defmodule JidokaTest.HandoffForwardExceptAgent do
  use Jidoka.Agent

  agent :handoff_forward_except_agent do
    model :fast
    instructions "Transfer public context except secrets."
  end

  tools do
    handoff(JidokaTest.BillingHandoffSpecialist,
      as: :billing_specialist,
      forward_context: {:except, [:secret]}
    )
  end
end

defmodule JidokaTest.PeerHandoffAgent do
  use Jidoka.Agent

  agent :peer_handoff_agent do
    model :fast
    instructions "Transfer ownership to an existing peer."
  end

  tools do
    handoff(JidokaTest.BillingHandoffSpecialist,
      as: :billing_specialist,
      target: {:peer, "billing-peer-handoff-test"}
    )
  end
end

defmodule JidokaTest.ContextPeerHandoffAgent do
  use Jidoka.Agent

  agent :context_peer_handoff_agent do
    model :fast
    instructions "Transfer ownership to a context-selected peer."
  end

  tools do
    handoff(JidokaTest.BillingHandoffSpecialist,
      as: :billing_specialist,
      target: {:peer, {:context, :billing_peer_id}}
    )
  end
end

defmodule JidokaTest.MissingPeerHandoffAgent do
  use Jidoka.Agent

  agent :missing_peer_handoff_agent do
    model :fast
    instructions "Transfer ownership to a peer that must exist."
  end

  tools do
    handoff(JidokaTest.BillingHandoffSpecialist,
      as: :billing_specialist,
      target: {:peer, "missing-billing-peer-handoff-test"}
    )
  end
end

defmodule JidokaTest.WrongPeerHandoffAgent do
  use Jidoka.Agent

  agent :wrong_peer_handoff_agent do
    model :fast
    instructions "Transfer ownership to a peer with the expected runtime."
  end

  tools do
    handoff(JidokaTest.BillingHandoffSpecialist,
      as: :billing_specialist,
      target: {:peer, "wrong-billing-peer-handoff-test"}
    )
  end
end

defmodule JidokaTest.StartFailureHandoffAgent do
  use Jidoka.Agent

  agent :start_failure_handoff_agent do
    model :fast
    instructions "Transfer ownership to a specialist that fails during startup."
  end

  tools do
    handoff(JidokaTest.StartFailureSpecialist,
      as: :start_failure_specialist,
      description: "Transfer to a specialist that cannot start."
    )
  end
end
