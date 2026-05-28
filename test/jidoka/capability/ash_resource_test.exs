defmodule JidokaTest.AshResourceTest do
  use JidokaTest.Support.Case, async: false

  test "expands ash_resource into generated AshJido action modules" do
    assert AshResourceAgent.ash_resources() == [User]
    assert AshResourceAgent.ash_domain() == Accounts
    assert AshResourceAgent.requires_actor?()
    assert Enum.sort(AshResourceAgent.tool_names()) == ["create_user", "list_users"]

    assert Enum.any?(AshResourceAgent.tools(), &(&1 == JidokaTest.Support.User.Jido.Create))
    assert Enum.any?(AshResourceAgent.tools(), &(&1 == JidokaTest.Support.User.Jido.Read))
  end

  test "requires actor in context for ash_resource agents" do
    assert {:ok, pid} = AshResourceAgent.start_link(id: "ash-resource-agent-test")

    try do
      assert {:error, %Jidoka.Error.ValidationError{} = error} =
               AshResourceAgent.chat(pid, "List users.")

      assert error.field == :actor
      assert error.details.reason == :missing_context
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "injects ash domain into internal tool_context for ash_resource agents" do
    assert {:ok, opts} =
             Jidoka.Agent.prepare_chat_opts(
               [context: %{actor: %{id: "user-1"}}],
               %{domain: Accounts, require_actor?: true}
             )

    assert Keyword.get(opts, :tool_context) == %{actor: %{id: "user-1"}, domain: Accounts}
  end

  test "rejects mismatched context domain for ash_resource agents" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts(
               [context: %{actor: %{id: "user-1"}, domain: :other_domain}],
               %{domain: Accounts, require_actor?: true}
             )

    assert error.field == :domain
    assert error.details.reason == :domain_mismatch
    assert error.details.expected == Accounts
    assert error.details.actual == :other_domain
  end
end
