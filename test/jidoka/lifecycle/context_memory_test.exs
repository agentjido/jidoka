defmodule JidokaTest.ContextMemoryTest do
  use JidokaTest.Support.Case, async: false

  alias JidokaTest.{
    ChatAgent,
    ContextAgent,
    ContextMemoryAgent,
    MemoryAgent,
    NoCaptureMemoryAgent,
    RequiredContextAgent,
    SharedMemoryAgent
  }

  test "accepts context keyword lists and normalizes them to internal tool_context" do
    assert {:ok, opts} =
             Jidoka.Agent.prepare_chat_opts([context: [tenant: "acme", locale: "en-US"]], nil)

    assert Keyword.get(opts, :tool_context) == %{tenant: "acme", locale: "en-US"}
  end

  test "passes naked context maps through agents without a schema" do
    assert {:ok, opts} =
             Jidoka.Agent.prepare_chat_opts(
               [context: %{tenant: "acme", actor_id: "user-1", ticket: %{id: "T-123"}}],
               nil
             )

    assert Keyword.get(opts, :tool_context) == %{
             tenant: "acme",
             actor_id: "user-1",
             ticket: %{id: "T-123"}
           }

    assert {:ok, pid} = ChatAgent.start_link(id: "naked-context-map-test")
    test_pid = self()

    guardrail = fn input ->
      send(test_pid, {:naked_context, Jidoka.Context.strip_internal(input.context)})
      {:interrupt, %{kind: :approval, message: "stop before provider", data: %{}}}
    end

    try do
      assert {:interrupt, %Jidoka.Interrupt{kind: :approval}} =
               Jidoka.chat(pid, "hello",
                 context: %{tenant: "acme", actor_id: "user-1", ticket: %{id: "T-123"}},
                 guardrails: [input: guardrail]
               )

      assert_receive {:naked_context,
                      %{
                        tenant: "acme",
                        actor_id: "user-1",
                        ticket: %{id: "T-123"}
                      }}
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "rejects malformed context lists with a structured validation error instead of raising" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts([context: [1, 2]], nil)

    assert error.field == :context
    assert error.details.reason == :expected_map
    assert Jidoka.format_error(error) == "Invalid context: pass `context:` as a map or keyword list."
  end

  test "merges default agent context with per-turn context" do
    assert {:ok, opts} =
             Jidoka.Agent.prepare_chat_opts(
               [context: %{session: "runtime"}],
               %{context: ContextAgent.context(), context_schema: ContextAgent.context_schema()}
             )

    assert Keyword.get(opts, :tool_context) == %{
             tenant: "demo",
             channel: "test",
             session: "runtime"
           }
  end

  test "validates runtime context through the agent schema" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts(
               [context: %{tenant: 123}],
               %{context: ContextAgent.context(), context_schema: ContextAgent.context_schema()}
             )

    assert error.details.reason == :schema
    assert inspect(error.details.errors) =~ "tenant"
  end

  test "coerces string keys that match atom fields in context schemas" do
    config = %{
      context: ContextAgent.context(),
      context_schema: ContextAgent.context_schema()
    }

    assert {:ok, opts} =
             Jidoka.Agent.prepare_chat_opts(
               [context: %{"tenant" => "acme", "session" => "runtime"}],
               config
             )

    assert Keyword.get(opts, :tool_context) == %{
             tenant: "acme",
             channel: "test",
             session: "runtime"
           }
  end

  test "keeps schema defaults when other context fields are required" do
    assert RequiredContextAgent.context() == %{tenant: "demo"}
  end

  test "central reserved context keys cover feature runtime keys" do
    feature_keys = [
      Jidoka.Character.context_key(),
      Jidoka.Compaction.context_key(),
      Jidoka.Handoff.context_key(),
      Jidoka.Memory.context_key(),
      Jidoka.Output.context_key(),
      Jidoka.Skill.context_key(),
      Jidoka.Subagent.request_id_key(),
      Jidoka.Subagent.server_key(),
      Jidoka.Subagent.depth_key()
    ]

    assert Enum.all?(feature_keys, &Jidoka.Context.reserved_key?/1)
    assert "__jidoka_character__" in Jidoka.Context.reserved_keys()
    assert "__jidoka_compaction__" in Jidoka.Context.reserved_keys()

    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Context.normalize(%{Jidoka.Character.context_key() => %{name: "private"}})

    assert error.details.reason == :reserved_context_key
    assert error.details.key == "__jidoka_character__"

    assert Jidoka.Context.strip_internal(%{
             Jidoka.Character.context_key() => %{name: "private"},
             Jidoka.Compaction.context_key() => %{summary: "private"},
             tenant: "acme"
           }) == %{tenant: "acme"}
  end

  test "validates required runtime context while applying schema defaults" do
    config = %{
      context: RequiredContextAgent.context(),
      context_schema: RequiredContextAgent.context_schema()
    }

    assert {:ok, opts} =
             Jidoka.Agent.prepare_chat_opts([context: %{account_id: "acct_123"}], config)

    assert Keyword.get(opts, :tool_context) == %{account_id: "acct_123", tenant: "demo"}

    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts([context: %{}], config)

    assert error.details.errors == %{account_id: ["is required"]}
  end

  test "Jidoka.chat validates context through the running agent schema" do
    assert {:ok, pid} = ContextAgent.start_link(id: "context-schema-chat")

    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.chat(pid, "hello", context: %{tenant: 123})

    assert inspect(error.details.errors) =~ "tenant"
    assert :ok = Jidoka.stop_agent(pid)
  end

  test "Jidoka.chat passes schema-normalized context into controls" do
    assert {:ok, pid} = ContextAgent.start_link(id: "context-schema-normalized-chat")
    test_pid = self()

    guardrail = fn input ->
      send(test_pid, {:schema_context, Jidoka.Context.strip_internal(input.context)})
      {:interrupt, %{kind: :approval, message: "stop before provider", data: %{}}}
    end

    try do
      assert {:interrupt, %Jidoka.Interrupt{kind: :approval}} =
               Jidoka.chat(pid, "hello",
                 context: %{tenant: "acme", session: "runtime"},
                 guardrails: [input: guardrail]
               )

      assert_receive {:schema_context,
                      %{
                        tenant: "acme",
                        channel: "test",
                        session: "runtime"
                      }}
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "merges default agent context into runtime requests" do
    runtime = ContextAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    assert {:ok, _agent, {:ai_react_start, params}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start, %{query: "hello", request_id: "req-context-1"}}
             )

    assert Jidoka.Context.strip_internal(params.tool_context) == %{tenant: "demo", channel: "test"}

    assert Jidoka.Context.strip_internal(params.runtime_context) == %{
             tenant: "demo",
             channel: "test"
           }
  end

  test "retrieves and captures conversation memory across turns" do
    agent = new_runtime_agent(MemoryAgent.runtime_module())
    session = "memory-session-#{System.unique_integer([:positive])}"
    config = MemoryAgent.memory_config()

    agent = start_ai_request(agent, "req-memory-1", "Remember that my favorite color is blue.")

    {:ok, agent, _action} =
      Jidoka.Memory.on_before_cmd(
        agent,
        {:ai_react_start,
         %{
           query: "Remember that my favorite color is blue.",
           request_id: "req-memory-1",
           tool_context: %{session: session}
         }},
        config,
        MemoryAgent.context()
      )

    agent =
      Jido.AI.Request.complete_request(
        agent,
        "req-memory-1",
        "I'll remember that your favorite color is blue."
      )

    assert {:ok, agent, []} =
             Jidoka.Memory.on_after_cmd(agent, {:ai_react_start, %{request_id: "req-memory-1"}}, [], config)

    agent = start_ai_request(agent, "req-memory-2", "What is my favorite color?")

    assert {:ok, agent, {:ai_react_start, params}} =
             Jidoka.Memory.on_before_cmd(
               agent,
               {:ai_react_start,
                %{
                  query: "What is my favorite color?",
                  request_id: "req-memory-2",
                  tool_context: %{session: session}
                }},
               config,
               MemoryAgent.context()
             )

    memory = params.tool_context[Jidoka.Memory.context_key()]
    assert memory.namespace == "agent:memory_agent:context:session:#{session}"
    assert Enum.map(memory.records, & &1.kind) == [:user_turn, :assistant_turn]
    assert params.runtime_context.session == session

    assert params.runtime_context[Jidoka.Memory.context_key()].namespace ==
             "agent:memory_agent:context:session:#{session}"

    assert memory.prompt =~ "Relevant memory:"
    assert memory.prompt =~ "favorite color is blue"

    assert get_in(agent.state, [:requests, "req-memory-2", :meta, :jidoka_memory, :namespace]) ==
             "agent:memory_agent:context:session:#{session}"
  end

  test "inject :context exposes retrieved memory on the runtime context" do
    agent = new_runtime_agent(ContextMemoryAgent.runtime_module())
    session = "context-memory-#{System.unique_integer([:positive])}"
    config = ContextMemoryAgent.memory_config()

    agent = start_ai_request(agent, "req-memory-ctx-1", "Remember that I prefer green tea.")

    {:ok, agent, _action} =
      Jidoka.Memory.on_before_cmd(
        agent,
        {:ai_react_start,
         %{
           query: "Remember that I prefer green tea.",
           request_id: "req-memory-ctx-1",
           tool_context: %{session: session}
         }},
        config,
        ContextMemoryAgent.context()
      )

    agent = Jido.AI.Request.complete_request(agent, "req-memory-ctx-1", "I'll remember that.")

    assert {:ok, agent, []} =
             Jidoka.Memory.on_after_cmd(agent, {:ai_react_start, %{request_id: "req-memory-ctx-1"}}, [], config)

    agent = start_ai_request(agent, "req-memory-ctx-2", "What drink do I prefer?")

    assert {:ok, _agent, {:ai_react_start, params}} =
             Jidoka.Memory.on_before_cmd(
               agent,
               {:ai_react_start,
                %{
                  query: "What drink do I prefer?",
                  request_id: "req-memory-ctx-2",
                  tool_context: %{session: session}
                }},
               config,
               ContextMemoryAgent.context()
             )

    assert ContextMemoryAgent.request_transformer() == JidokaTest.ContextMemoryAgent.RuntimeRequestTransformer
    assert %{namespace: _, records: [_user, _assistant]} = params.tool_context[:memory]
  end

  test "shared memory namespaces are visible across agent instances" do
    runtime = SharedMemoryAgent.runtime_module()
    first_agent = new_runtime_agent(runtime)
    second_agent = new_runtime_agent(runtime)
    config = SharedMemoryAgent.memory_config()

    first_agent = start_ai_request(first_agent, "req-memory-shared-1", "Remember that the shared color is red.")

    {:ok, first_agent, _action} =
      Jidoka.Memory.on_before_cmd(
        first_agent,
        {:ai_react_start, %{query: "Remember that the shared color is red.", request_id: "req-memory-shared-1"}},
        config,
        SharedMemoryAgent.context()
      )

    first_agent = Jido.AI.Request.complete_request(first_agent, "req-memory-shared-1", "Stored.")

    assert {:ok, _first_agent, []} =
             Jidoka.Memory.on_after_cmd(
               first_agent,
               {:ai_react_start, %{request_id: "req-memory-shared-1"}},
               [],
               config
             )

    second_agent = start_ai_request(second_agent, "req-memory-shared-2", "What is the shared color?")

    assert {:ok, _second_agent, {:ai_react_start, params}} =
             Jidoka.Memory.on_before_cmd(
               second_agent,
               {:ai_react_start, %{query: "What is the shared color?", request_id: "req-memory-shared-2"}},
               config,
               SharedMemoryAgent.context()
             )

    assert params.tool_context[:memory].namespace == "shared:shared-demo"

    assert Enum.any?(params.tool_context[:memory].records, fn record ->
             to_string(record.kind) == "user_turn" and
               String.contains?(record.text || "", "shared color is red")
           end)
  end

  test "capture :off skips conversation writes" do
    agent = new_runtime_agent(NoCaptureMemoryAgent.runtime_module())
    session = "memory-off-#{System.unique_integer([:positive])}"
    config = NoCaptureMemoryAgent.memory_config()

    agent = start_ai_request(agent, "req-memory-off-1", "Remember that I like coffee.")

    {:ok, agent, _action} =
      Jidoka.Memory.on_before_cmd(
        agent,
        {:ai_react_start,
         %{
           query: "Remember that I like coffee.",
           request_id: "req-memory-off-1",
           tool_context: %{session: session}
         }},
        config,
        NoCaptureMemoryAgent.context()
      )

    agent = Jido.AI.Request.complete_request(agent, "req-memory-off-1", "I will not store this.")

    assert {:ok, agent, []} =
             Jidoka.Memory.on_after_cmd(agent, {:ai_react_start, %{request_id: "req-memory-off-1"}}, [], config)

    agent = start_ai_request(agent, "req-memory-off-2", "What drink do I like?")

    assert {:ok, _agent, {:ai_react_start, params}} =
             Jidoka.Memory.on_before_cmd(
               agent,
               {:ai_react_start,
                %{
                  query: "What drink do I like?",
                  request_id: "req-memory-off-2",
                  tool_context: %{session: session}
                }},
               config,
               NoCaptureMemoryAgent.context()
             )

    assert params.tool_context[:memory].records == []
  end

  test "rejects public tool_context in favor of context" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts([tool_context: %{actor: %{id: "user-1"}}], nil)

    assert error.field == :tool_context
    assert error.details.reason == :use_context
  end

  test "rejects public tool_context in chat helpers" do
    assert {:ok, pid} = ChatAgent.start_link(id: "invalid-tool-context-chat-test")

    try do
      assert {:error, %Jidoka.Error.ValidationError{} = chat_error} =
               ChatAgent.chat(pid, "Hello", tool_context: %{tenant: "acme"})

      assert {:error, %Jidoka.Error.ValidationError{} = jidoka_error} =
               Jidoka.chat(pid, "Hello", tool_context: %{tenant: "acme"})

      assert chat_error.details.reason == :use_context
      assert jidoka_error.details.reason == :use_context
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  defp start_ai_request(agent, request_id, query) do
    Jido.AI.Request.start_request(agent, request_id, query)
  end
end
