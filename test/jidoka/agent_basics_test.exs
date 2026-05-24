defmodule JidokaTest.AgentBasicsTest do
  use JidokaTest.Support.Case, async: false

  alias JidokaTest.{
    CharacterAgent,
    ChatAgent,
    ContextAgent,
    InlineMapModelAgent,
    MemoryAgent,
    MCPAgent,
    MfaPromptAgent,
    RequiredContextAgent,
    RuntimeSkillAgent,
    SkillAgent,
    ModulePromptAgent,
    ModuleCharacterAgent,
    PromptCallbacks,
    StringModelAgent,
    StructModelAgent,
    SupportCharacter,
    TenantPrompt
  }

  test "starts a jidoka agent under the shared runtime" do
    assert {:ok, pid} = ChatAgent.start_link(id: "chat-agent-test")
    assert Jidoka.whereis("chat-agent-test") == pid
    assert {"chat-agent-test", pid} in Jidoka.list_agents()
    assert :ok = Jidoka.stop_agent(pid)
  end

  test "exposes the stable agent id" do
    assert ChatAgent.id() == "chat_agent"
    assert ChatAgent.name() == "chat_agent"
    assert ChatAgent.runtime_module() == JidokaTest.ChatAgent.Runtime
  end

  test "exposes the canonical V3 generated helper surface" do
    definition = ChatAgent.__jidoka__()

    assert definition.kind == :agent_definition
    assert definition.id == "chat_agent"
    assert definition.runtime_module == ChatAgent.runtime_module()
    assert Map.has_key?(definition, :result)
    refute Map.has_key?(definition, :output)

    assert function_exported?(ChatAgent, :chat, 3)
    assert function_exported?(ChatAgent, :start_link, 1)
    assert function_exported?(ChatAgent, :result, 0)
    assert function_exported?(ChatAgent, :result_schema, 0)
    assert function_exported?(ChatAgent, :controls, 0)
    assert function_exported?(ChatAgent, :input_controls, 0)
    assert function_exported?(ChatAgent, :operation_controls, 0)
    assert function_exported?(ChatAgent, :result_controls, 0)

    refute function_exported?(ChatAgent, :output, 0)
    refute function_exported?(ChatAgent, :output_schema, 0)
    refute function_exported?(ChatAgent, :guardrails, 0)
    refute function_exported?(ChatAgent, :input_guardrails, 0)
    refute function_exported?(ChatAgent, :tool_guardrails, 0)
    refute function_exported?(ChatAgent, :output_guardrails, 0)

    assert ChatAgent.result() == nil
    assert ChatAgent.result_schema() == nil
    assert ChatAgent.controls() == %{input: [], output: [], tool: []}
  end

  test "exposes the configured instructions" do
    assert ChatAgent.instructions() == "You are a concise assistant."
    assert ChatAgent.character() == nil
    assert ChatAgent.request_transformer() == JidokaTest.ChatAgent.RuntimeRequestTransformer
  end

  test "exposes the configured default context" do
    assert ContextAgent.context() == %{tenant: "demo", channel: "test"}
    assert %Zoi.Types.Map{} = ContextAgent.context_schema()

    assert RequiredContextAgent.context() == %{tenant: "demo"}
    assert %Zoi.Types.Map{} = RequiredContextAgent.context_schema()
  end

  test "exposes the configured memory settings" do
    assert MemoryAgent.memory() == %{
             mode: :conversation,
             namespace: {:context, :session},
             capture: :conversation,
             retrieve: %{limit: 4},
             inject: :instructions
           }

    assert ChatAgent.memory() == nil
  end

  test "memory agents replace the default Jido memory plugin with jido_memory" do
    instances = MemoryAgent.runtime_module().plugin_instances()
    modules = Enum.map(instances, & &1.module)
    memory_instance = Enum.find(instances, &(&1.module == Jido.Memory.BasicPlugin))
    runtime_agent = MemoryAgent.runtime_module().new(id: "memory-default-slot")

    assert Jido.Memory.BasicPlugin in modules
    refute Jido.Memory.Plugin in modules
    assert memory_instance.state_key == :__memory__
    assert runtime_agent.state[:__memory__].namespace == "agent:memory-default-slot"
  end

  test "agents without Jidoka memory disable the default Jido memory plugin" do
    modules = ChatAgent.runtime_module().plugins()

    refute Jido.Memory.Plugin in modules
    refute Jido.Memory.BasicPlugin in modules
  end

  test "runtime helper composes plugins and exposes hook runtime AST" do
    assert Jidoka.Agent.Runtime.runtime_plugins([JidokaTest.MathPlugin], nil) == [
             Jidoka.Plugins.RuntimeCompat,
             JidokaTest.MathPlugin
           ]

    ast =
      Jidoka.Agent.Runtime.hook_runtime_ast(
        Jidoka.Hooks.default_stage_map(),
        %{},
        Jidoka.Guardrails.default_stage_map()
      )

    rendered = Macro.to_string(ast)

    assert rendered =~ "def on_before_cmd"
    assert rendered =~ "Jidoka.Memory.on_before_cmd"
  end

  test "exposes configured skills and mcp settings" do
    assert SkillAgent.skills() == %{refs: [JidokaTest.ModuleMathSkill], load_paths: []}
    assert SkillAgent.skill_names() == ["module-math-skill"]
    assert SkillAgent.request_transformer() == JidokaTest.SkillAgent.RuntimeRequestTransformer

    assert RuntimeSkillAgent.skills() == %{
             refs: ["math-discipline"],
             load_paths: [Path.expand("../fixtures/skills", "test/support")]
           }

    assert RuntimeSkillAgent.skill_names() == ["math-discipline"]
    assert MCPAgent.mcp_tools() == [%{endpoint: :github, prefix: "github_"}]
  end

  test "supports module-based dynamic instructions" do
    assert ModulePromptAgent.instructions() == TenantPrompt

    assert ModulePromptAgent.request_transformer() ==
             JidokaTest.ModulePromptAgent.RuntimeRequestTransformer

    request = react_request([%{role: :user, content: "hello"}])
    state = react_state()
    config = react_config(ModulePromptAgent.request_transformer())

    assert {:ok, %{messages: messages}} =
             ModulePromptAgent.request_transformer().transform_request(
               request,
               state,
               config,
               %{tenant: "acme"}
             )

    assert messages == [
             %{role: :system, content: "You are helping tenant acme."},
             %{role: :user, content: "hello"}
           ]
  end

  test "supports MFA-based dynamic instructions" do
    assert MfaPromptAgent.instructions() == {PromptCallbacks, :build, ["Serve tenant"]}

    assert MfaPromptAgent.request_transformer() ==
             JidokaTest.MfaPromptAgent.RuntimeRequestTransformer

    request =
      react_request([%{role: :system, content: "stale"}, %{role: :user, content: "hello"}])

    state = react_state()
    config = react_config(MfaPromptAgent.request_transformer())

    assert {:ok, %{messages: messages}} =
             MfaPromptAgent.request_transformer().transform_request(
               request,
               state,
               config,
               %{"tenant" => "beta"}
             )

    assert messages == [
             %{role: :system, content: "Serve tenant beta."},
             %{role: :user, content: "hello"}
           ]
  end

  test "composes compile-time map characters before instructions" do
    assert CharacterAgent.character().name == "Policy Advisor"
    assert CharacterAgent.request_transformer() == JidokaTest.CharacterAgent.RuntimeRequestTransformer

    request = react_request([%{role: :user, content: "hello"}])
    state = react_state()
    config = react_config(CharacterAgent.request_transformer())

    assert {:ok, %{messages: [%{role: :system, content: prompt}, %{role: :user, content: "hello"}]}} =
             CharacterAgent.request_transformer().transform_request(request, state, config, %{})

    assert prompt =~ "# Character: Policy Advisor"
    assert prompt =~ "- Role: Support policy specialist"
    assert prompt =~ "Tone: Professional"
    assert prompt =~ "Stay within published policy."
    assert prompt =~ "Answer with the support policy first."
  end

  test "composes compile-time Jido.Character modules" do
    assert ModuleCharacterAgent.character() == SupportCharacter

    request = react_request([%{role: :user, content: "hello"}])
    state = react_state()
    config = react_config(ModuleCharacterAgent.request_transformer())

    assert {:ok, %{messages: [%{role: :system, content: prompt}, %{role: :user, content: "hello"}]}} =
             ModuleCharacterAgent.request_transformer().transform_request(
               request,
               state,
               config,
               %{}
             )

    assert prompt =~ "# Character: Support Advisor"
    assert prompt =~ "- Role: Support specialist"
    assert prompt =~ "Use the configured support persona."
    assert prompt =~ "Adapt the response to the account tier."
  end

  test "supports runtime character overrides in chat options" do
    assert {:ok, opts} =
             Jidoka.Agent.prepare_chat_opts(
               [
                 character: %{
                   name: "Runtime Advisor",
                   voice: %{tone: :warm},
                   instructions: ["Use runtime persona."]
                 }
               ],
               %{context: %{}, context_schema: nil}
             )

    runtime_context = Keyword.fetch!(opts, :tool_context)

    request = react_request([%{role: :user, content: "hello"}])
    state = react_state()
    config = react_config(ChatAgent.request_transformer())

    assert {:ok, %{messages: [%{role: :system, content: prompt}, %{role: :user, content: "hello"}]}} =
             ChatAgent.request_transformer().transform_request(request, state, config, runtime_context)

    assert prompt =~ "# Character: Runtime Advisor"
    assert prompt =~ "Tone: Warm"
    assert prompt =~ "Use runtime persona."
    assert prompt =~ "You are a concise assistant."
  end

  test "rejects invalid runtime characters" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts([character: 42], nil)

    assert error.field == :character
    assert error.details.reason == :invalid_character

    assert {:error, %Jidoka.Error.ValidationError{} = string_error} =
             Jidoka.Agent.prepare_chat_opts([character: "rendered character prompt"], nil)

    assert string_error.field == :character
    assert string_error.details.reason == :invalid_character
    assert string_error.details.cause =~ "must be a map"
  end

  test "appends retrieved memory to the effective system prompt" do
    assert MemoryAgent.request_transformer() == JidokaTest.MemoryAgent.RuntimeRequestTransformer

    request = react_request([%{role: :user, content: "hello"}])
    state = react_state()
    config = react_config(MemoryAgent.request_transformer())

    assert {:ok, %{messages: messages}} =
             MemoryAgent.request_transformer().transform_request(
               request,
               state,
               config,
               %{
                 Jidoka.Memory.context_key() => %{
                   prompt: "Relevant memory:\n- User: My favorite color is blue."
                 }
               }
             )

    assert messages == [
             %{
               role: :system,
               content: "You have conversation memory.\n\nRelevant memory:\n- User: My favorite color is blue."
             },
             %{role: :user, content: "hello"}
           ]
  end

  test "resolves Jidoka-owned aliases and falls back to Jido.AI aliases" do
    assert Jidoka.model_aliases()[:fast] == "anthropic:claude-haiku-4-5"
    assert Jidoka.model(:fast) == "anthropic:claude-haiku-4-5"
    assert Jidoka.model(:capable) == Jido.AI.resolve_model(:capable)
    assert ChatAgent.configured_model() == :fast
    assert ChatAgent.model() == "anthropic:claude-haiku-4-5"
  end

  test "passes through direct model strings" do
    assert StringModelAgent.configured_model() == "openai:gpt-4.1"
    assert StringModelAgent.model() == "openai:gpt-4.1"
  end

  test "passes through inline model maps" do
    expected = %{provider: :openai, id: "gpt-4.1", base_url: "http://localhost:4000/v1"}

    assert InlineMapModelAgent.configured_model() == expected
    assert InlineMapModelAgent.model() == expected
  end

  test "passes through %LLMDB.Model{} structs" do
    assert %LLMDB.Model{id: "gpt-4.1", provider: :openai} = StructModelAgent.configured_model()
    assert %LLMDB.Model{id: "gpt-4.1", provider: :openai} = StructModelAgent.model()
  end

  test "Jidoka.chat returns not_found for missing ids" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.chat("missing-agent-id", "hello")

    assert error.message == "Jidoka agent could not be found."
    assert error.details.reason == :not_found
    assert error.details.cause == :not_found
  end
end
