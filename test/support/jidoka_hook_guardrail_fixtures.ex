defmodule JidokaTest.InjectTenantHook do
  use Jidoka.Hook, name: "inject_tenant"

  @impl true
  def call(%Jidoka.Hooks.BeforeTurn{} = input) do
    sequence = Map.get(input.metadata, :sequence, [])

    {:ok,
     %{
       message: "#{input.message} for acme",
       context: %{tenant: "acme"},
       allowed_tools: ["add_numbers"],
       llm_opts: [temperature: 0.1],
       metadata: %{sequence: sequence ++ ["inject_tenant"], touched?: true}
     }}
  end
end

defmodule JidokaTest.RestrictRefundsHook do
  use Jidoka.Hook, name: "restrict_refunds"

  @impl true
  def call(%Jidoka.Hooks.BeforeTurn{} = input) do
    sequence = Map.get(input.metadata, :sequence, [])
    {:ok, %{metadata: %{sequence: sequence ++ ["restrict_refunds"], mode: :refunds}}}
  end
end

defmodule JidokaTest.NormalizeReplyHook do
  use Jidoka.Hook, name: "normalize_reply"

  @impl true
  def call(%Jidoka.Hooks.AfterTurn{outcome: {:ok, result}}) do
    {:ok, {:ok, "normalized:#{result}"}}
  end

  def call(%Jidoka.Hooks.AfterTurn{outcome: {:error, reason}}) do
    {:ok, {:error, {:normalized_error, reason}}}
  end
end

defmodule JidokaTest.InterruptBeforeHook do
  use Jidoka.Hook, name: "approval_gate"

  @impl true
  def call(%Jidoka.Hooks.BeforeTurn{} = input) do
    notify_pid = Map.get(input.context, :notify_pid, Map.get(input.context, "notify_pid"))

    {:interrupt,
     %{
       kind: :approval,
       message: "Approval required",
       data: %{notify_pid: notify_pid, from: :before_turn}
     }}
  end
end

defmodule JidokaTest.InterruptAfterHook do
  use Jidoka.Hook, name: "interrupt_after_turn"

  @impl true
  def call(%Jidoka.Hooks.AfterTurn{} = input) do
    notify_pid = Map.get(input.context, :notify_pid, Map.get(input.context, "notify_pid"))

    {:interrupt,
     %{
       kind: :review,
       message: "Review required",
       data: %{notify_pid: notify_pid, from: :after_turn}
     }}
  end
end

defmodule JidokaTest.NotifyOpsHook do
  use Jidoka.Hook, name: "notify_ops"

  @impl true
  def call(%Jidoka.Hooks.InterruptInput{interrupt: interrupt}) do
    if pid = get_in(interrupt.data, [:notify_pid]) do
      send(pid, {:hook_interrupt, interrupt.kind, interrupt.data[:from]})
    end

    :ok
  end
end

defmodule JidokaTest.HookCallbacks do
  def before_turn(%Jidoka.Hooks.BeforeTurn{} = input, label) do
    sequence = Map.get(input.metadata, :sequence, [])
    {:ok, %{metadata: %{sequence: sequence ++ [label]}}}
  end

  def after_turn(%Jidoka.Hooks.AfterTurn{outcome: {:ok, result}}, suffix) do
    {:ok, {:ok, "#{result}#{suffix}"}}
  end

  def after_turn(%Jidoka.Hooks.AfterTurn{outcome: {:error, reason}}, suffix) do
    {:ok, {:error, {suffix, reason}}}
  end

  def notify_interrupt(%Jidoka.Hooks.InterruptInput{interrupt: interrupt}, label) do
    if pid = get_in(interrupt.data, [:notify_pid]) do
      send(pid, {:hook_interrupt_callback, label, interrupt.kind})
    end

    :ok
  end
end

defmodule JidokaTest.SafePromptGuardrail do
  use Jidoka.Guardrail, name: "safe_prompt"

  @impl true
  def call(%Jidoka.Guardrails.Input{message: message}) do
    if String.contains?(String.downcase(message), "secret") do
      {:error, :unsafe_prompt}
    else
      :ok
    end
  end
end

defmodule JidokaTest.SafeReplyGuardrail do
  use Jidoka.Guardrail, name: "safe_reply"

  @impl true
  def call(%Jidoka.Guardrails.Output{outcome: {:ok, result}}) when is_binary(result) do
    if String.contains?(String.downcase(result), "unsafe") do
      {:error, :unsafe_reply}
    else
      :ok
    end
  end

  def call(%Jidoka.Guardrails.Output{}), do: :ok
end

defmodule JidokaTest.ApproveLargeMathToolGuardrail do
  use Jidoka.Guardrail, name: "approve_large_math_tool"

  @impl true
  def call(%Jidoka.Guardrails.Tool{
        tool_name: "add_numbers",
        arguments: arguments,
        context: context
      }) do
    a = Map.get(arguments, :a, Map.get(arguments, "a", 0))
    b = Map.get(arguments, :b, Map.get(arguments, "b", 0))

    if a + b > 40 do
      notify_pid = Map.get(context, :notify_pid, Map.get(context, "notify_pid"))

      {:interrupt,
       %{
         kind: :approval,
         message: "Large calculations require approval",
         data: %{notify_pid: notify_pid, from: :tool_guardrail}
       }}
    else
      :ok
    end
  end

  def call(%Jidoka.Guardrails.Tool{}), do: :ok
end

defmodule JidokaTest.GuardrailCallbacks do
  def input(%Jidoka.Guardrails.Input{} = input, label) do
    sequence = Map.get(input.metadata, :sequence, [])

    if String.contains?(input.message, "blocked_by_#{label}") do
      {:error, {:blocked, label}}
    else
      {:error, {:input_callback, sequence ++ [label]}}
    end
  end

  def output(%Jidoka.Guardrails.Output{}, label), do: {:error, {:output_callback, label}}
  def tool(%Jidoka.Guardrails.Tool{}, label), do: {:error, {:tool_callback, label}}
end

defmodule JidokaTest.HookedAgent do
  use Jidoka.Agent

  agent :hooked_agent do
    model :fast
    instructions "You have hooks."
  end

  lifecycle do
    before_turn JidokaTest.InjectTenantHook
    before_turn {JidokaTest.HookCallbacks, :before_turn, ["dsl_mfa"]}
    after_turn JidokaTest.NormalizeReplyHook
    after_turn {JidokaTest.HookCallbacks, :after_turn, ["!"]}
    on_interrupt JidokaTest.NotifyOpsHook
    on_interrupt {JidokaTest.HookCallbacks, :notify_interrupt, ["dsl_mfa"]}
  end
end

defmodule JidokaTest.GuardrailedAgent do
  use Jidoka.Agent

  agent :guardrailed_agent do
    model :fast
    instructions "You enforce guardrails."
  end

  capabilities do
    tool JidokaTest.AddNumbers
  end

  lifecycle do
    on_interrupt JidokaTest.NotifyOpsHook

    input_guardrail JidokaTest.SafePromptGuardrail
    output_guardrail JidokaTest.SafeReplyGuardrail
    tool_guardrail JidokaTest.ApproveLargeMathToolGuardrail
  end
end

defmodule JidokaTest.InterruptingAgent do
  use Jidoka.Agent

  agent :interrupting_agent do
    model :fast
    instructions "You may interrupt."
  end

  lifecycle do
    before_turn JidokaTest.InterruptBeforeHook
    on_interrupt JidokaTest.NotifyOpsHook
  end
end
