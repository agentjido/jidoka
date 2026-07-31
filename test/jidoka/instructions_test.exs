defmodule Jidoka.InstructionsTest.Support.Provider do
  @behaviour Jidoka.Instructions

  @impl true
  def resolve(base, context) do
    {:ok, "#{base} Tenant: #{context.data.tenant_id}."}
  end
end

defmodule Jidoka.InstructionsTest.Support.HostedAgent do
  use Jidoka.Agent

  agent :hosted_dynamic_instructions do
    model %{provider: :test, id: "model"}
    instructions "Use the tenant policy."
  end
end

defmodule Jidoka.InstructionsTest do
  use ExUnit.Case, async: true

  alias Jidoka.Harness
  alias Jidoka.InstructionsTest.Support.HostedAgent
  alias Jidoka.InstructionsTest.Support.Provider

  defp spec do
    Jidoka.Agent.Spec.new!(
      id: "dynamic_instructions",
      instructions: "Use the tenant policy.",
      model: %{provider: :test, id: "model"},
      context_schema: Zoi.object(%{tenant_id: Zoi.string()})
    )
  end

  test "resolves request instructions from public context" do
    test_pid = self()

    instructions = fn base, context ->
      send(test_pid, {:instruction_context, base, context})
      "#{base} Tenant: #{context.data.tenant_id}."
    end

    llm = fn intent, _journal, _context ->
      send(test_pid, {:model_prompt, intent.payload.prompt})
      {:ok, %{type: :final, content: "ok"}}
    end

    context =
      Jidoka.Context.new!(
        data: %{tenant_id: "tenant_1"},
        runtime: %{api_key: "secret"}
      )

    assert {:ok, result} =
             Jidoka.turn(spec(), "Help me",
               context: context,
               instructions: instructions,
               llm: llm,
               request_id: "req_dynamic"
             )

    assert_receive {:instruction_context, "Use the tenant policy.", provider_context}
    assert provider_context.agent_id == "dynamic_instructions"
    assert provider_context.request_id == "req_dynamic"
    assert provider_context.input == "Help me"
    assert provider_context.data == %{tenant_id: "tenant_1"}
    assert provider_context.runtime == %{}
    assert provider_context.request == nil
    assert provider_context.plan == nil

    assert_receive {:model_prompt, prompt}

    assert [%{role: :system, content: "Use the tenant policy. Tenant: tenant_1."} | _rest] =
             prompt.messages

    assert hd(result.metadata.debug.prompt.messages).content ==
             "Use the tenant policy. Tenant: tenant_1."

    assert spec().instructions == "Use the tenant policy."
  end

  test "uses the same module provider during preflight and session turns" do
    assert {:ok, preflight} =
             Jidoka.preflight(spec(), "Preview",
               context: %{tenant_id: "tenant_2"},
               instructions: Provider
             )

    assert [%{role: :system, content: "Use the tenant policy. Tenant: tenant_2."} | _rest] =
             preflight.prompt.messages

    assert {:ok, session} = Harness.start_session(spec(), session_id: "dynamic_session")

    llm = fn _intent, _journal, _context ->
      {:ok, %{type: :final, content: "done"}}
    end

    assert {:ok, _session, result} =
             Harness.run_session(session, "Run",
               context: %{tenant_id: "tenant_3"},
               instructions: Provider,
               llm: llm
             )

    assert hd(result.metadata.debug.prompt.messages).content ==
             "Use the tenant policy. Tenant: tenant_3."
  end

  test "resolves instructions for a process-hosted agent" do
    id = "dynamic_instructions_#{System.unique_integer([:positive])}"
    test_pid = self()

    llm = fn intent, _journal, _context ->
      send(test_pid, {:hosted_prompt, intent.payload.prompt})
      {:ok, %{type: :final, content: "hosted"}}
    end

    assert {:ok, pid} = HostedAgent.start(id: id)
    on_exit(fn -> Jidoka.stop_agent(pid) end)

    assert {:ok, _result} =
             Jidoka.turn(pid, "Run",
               context: %{tenant_id: "tenant_4"},
               instructions: Provider,
               llm: llm
             )

    assert_receive {:hosted_prompt, prompt}

    assert hd(prompt.messages).content ==
             "Use the tenant policy. Tenant: tenant_4."
  end

  test "stores resolved instructions in a snapshot and does not resolve them again" do
    test_pid = self()

    instructions = fn base, _context ->
      send(test_pid, :instructions_resolved)
      "#{base} Keep this value."
    end

    llm = fn _intent, _journal, _context ->
      {:ok, %{type: :final, content: "resumed"}}
    end

    assert {:hibernate, snapshot} =
             Jidoka.turn(spec(), "Pause",
               context: %{tenant_id: "tenant_6"},
               instructions: instructions,
               checkpoint: :after_prompt,
               llm: llm
             )

    assert_receive :instructions_resolved
    refute_receive :instructions_resolved

    assert {:ok, result} = Jidoka.resume(snapshot, llm: llm)
    refute_receive :instructions_resolved
    assert hd(result.metadata.debug.prompt.messages).content == "Use the tenant policy. Keep this value."
  end

  test "rejects invalid values and normalizes provider failures" do
    opts = [context: %{tenant_id: "tenant_5"}]

    assert {:error, invalid} = Jidoka.turn(spec(), "Run", Keyword.put(opts, :instructions, " "))
    assert Jidoka.Error.category(invalid) == :validation

    provider = fn _base, _context -> {:error, :policy_unavailable} end

    assert {:error, failed} = Jidoka.turn(spec(), "Run", Keyword.put(opts, :instructions, provider))
    assert Jidoka.Error.category(failed) == :execution
    assert Jidoka.Error.to_map(failed).details.cause == :policy_unavailable
  end
end
