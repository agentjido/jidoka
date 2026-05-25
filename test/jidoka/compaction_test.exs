defmodule JidokaTest.CompactionTest do
  use JidokaTest.Support.Case, async: false

  alias Jido.Thread
  alias Jido.Thread.Agent, as: ThreadAgent
  alias Jidoka.Compaction
  alias Jidoka.Compaction.Prompt

  alias JidokaTest.{
    ChatAgent,
    CompactionAgent,
    CompactionPrompt,
    CompactionPromptCallbacks,
    CompactionSummarizer,
    EmptyCompactionPrompt,
    ErrorCompactionPrompt,
    InvalidCompactionPrompt,
    ManualCompactionAgent,
    MoreCompactionPromptCallbacks,
    RaisingCompactionPrompt
  }

  setup do
    previous = Application.get_env(:jidoka, :compaction_summarizer)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:jidoka, :compaction_summarizer)
      else
        Application.put_env(:jidoka, :compaction_summarizer, previous)
      end
    end)

    :ok
  end

  test "agents expose configured compaction settings" do
    assert %{
             mode: :auto,
             strategy: :summary,
             max_messages: 4,
             keep_last: 2,
             max_summary_chars: 120,
             prompt: "Compact the transcript for this test."
           } = CompactionAgent.compaction()

    assert ChatAgent.compaction() == nil
  end

  test "public compaction helpers expose defaults, enablement, prompt text, and message windows" do
    assert %{mode: :auto, strategy: :summary, keep_last: 12} = Compaction.default_config()
    refute Compaction.enabled?(nil)
    refute Compaction.enabled?(%{mode: :off})
    assert Compaction.enabled?(%{mode: :manual})

    compaction = %Compaction{status: :summarized, summary: "Earlier context.", retained_message_count: 1}

    assert Compaction.prompt_text(%{Compaction.context_key() => compaction}) ==
             "Compacted conversation summary:\nEarlier context."

    assert Compaction.prompt_text(%{
             Atom.to_string(Compaction.context_key()) => %{summary: "From strings.", keep_last: 1}
           }) ==
             "Compacted conversation summary:\nFrom strings."

    assert Compaction.prompt_text(%{Compaction.context_key() => %{summary: "", keep_last: 1}}) == nil
    assert Compaction.prompt_text(:not_a_context) == nil

    messages = [
      %{role: :system, content: "system"},
      %{"role" => "user", "content" => "old"},
      %{role: :assistant, content: "recent"},
      %{role: :alien, content: "unknown"}
    ]

    assert [
             %{role: :assistant, content: "recent"},
             %{role: :alien, content: "unknown"}
           ] =
             Compaction.apply_to_messages(messages, %{Compaction.context_key() => %{summary: "summary", keep_last: 2}})

    assert Compaction.apply_to_messages(messages, %{Compaction.context_key() => %{summary: "summary"}}) == messages
    assert Compaction.apply_to_messages(messages, :not_a_context) == messages
  end

  test "normalizes prompt overrides and rejects invalid compaction config" do
    assert {:ok, %{prompt: CompactionPrompt}} =
             Compaction.normalize_dsl([%Jidoka.Agent.Dsl.CompactionPrompt{value: CompactionPrompt}])

    assert {:ok, %{prompt: {CompactionPromptCallbacks, :build, ["prefix"]}}} =
             Compaction.normalize_dsl([
               %Jidoka.Agent.Dsl.CompactionPrompt{value: {CompactionPromptCallbacks, :build, ["prefix"]}}
             ])

    assert {:error, reason} =
             Compaction.normalize_dsl([
               %Jidoka.Agent.Dsl.CompactionMaxMessages{value: 2},
               %Jidoka.Agent.Dsl.CompactionKeepLast{value: 2}
             ])

    assert reason =~ "keep_last must be less than max_messages"
  end

  test "compaction prompt validation rejects ambiguous runtime-only prompt specs" do
    assert Prompt.default_prompt() =~ "Compress the conversation for the next agent turn."

    assert {:error, reason} = Prompt.normalize(nil, " ")
    assert reason =~ "must not be empty"

    assert {:error, reason} = Prompt.normalize(nil, fn _input -> "compact" end)
    assert reason =~ "does not support anonymous functions"

    assert {:error, reason} = Prompt.normalize(nil, String)
    assert reason =~ "must implement build_compaction_prompt/1"

    assert {:error, reason} = Prompt.normalize(nil, {MoreCompactionPromptCallbacks, :missing, []})
    assert reason =~ "must export missing/1"

    assert {:error, reason} = Prompt.normalize(nil, %{prompt: "compact"})
    assert reason =~ "must be a string"
  end

  test "compaction prompt resolution handles default, module, and MFA prompt sources" do
    input = %{source_message_count: 3, retained_message_count: 2}

    assert {:ok, default_prompt} = Prompt.resolve(nil, input)
    assert default_prompt =~ "Preserve only durable context:"

    assert Prompt.resolve("Use a static prompt.", input) == {:ok, "Use a static prompt."}
    assert Prompt.resolve(CompactionPrompt, input) == {:ok, "Custom compact 3 messages."}

    assert Prompt.resolve(EmptyCompactionPrompt, input) ==
             {:error, "dynamic compaction prompt must not resolve to an empty string"}

    assert Prompt.resolve(ErrorCompactionPrompt, input) == {:error, :prompt_failed}

    assert {:error, reason} = Prompt.resolve(InvalidCompactionPrompt, input)
    assert reason =~ "must return a string"

    assert {:error, reason} = Prompt.resolve(RaisingCompactionPrompt, input)
    assert reason =~ "prompt boom"

    assert Prompt.resolve({MoreCompactionPromptCallbacks, :ok, ["prefix"]}, input) ==
             {:ok, "prefix: 3 source."}

    assert Prompt.resolve({MoreCompactionPromptCallbacks, :error, []}, input) == {:error, :mfa_failed}

    assert Prompt.resolve({MoreCompactionPromptCallbacks, :empty, []}, input) ==
             {:error, "dynamic compaction prompt must not resolve to an empty string"}

    assert {:error, reason} = Prompt.resolve({MoreCompactionPromptCallbacks, :invalid, []}, input)
    assert reason =~ "must return a string"

    assert {:error, reason} = Prompt.resolve({MoreCompactionPromptCallbacks, :raise_error, []}, input)
    assert reason =~ "mfa boom"
  end

  test "auto compaction summarizes old thread messages and attaches runtime context" do
    test_pid = self()

    Application.put_env(:jidoka, :compaction_summarizer, fn input ->
      send(test_pid, {:compaction_input, input.prompt, input.source_message_count, input.retained_message_count})
      {:ok, "summary from #{input.source_message_count} messages"}
    end)

    runtime = CompactionAgent.runtime_module()

    agent =
      runtime
      |> new_runtime_agent()
      |> put_thread([
        ai_message(:user, "old 1", request_id: "req-1"),
        ai_message(:assistant, "old 2", request_id: "req-1"),
        ai_message(:user, "old 3", request_id: "req-2"),
        ai_message(:assistant, "old 4", request_id: "req-2"),
        ai_message(:user, "recent 1", request_id: "req-3"),
        ai_message(:assistant, "recent 2", request_id: "req-3")
      ])

    assert {:ok, updated_agent, {:ai_react_start, params}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start,
                %{
                  query: "next",
                  request_id: "req-compact",
                  tool_context: %{conversation_id: "conv-1"}
                }}
             )

    assert_receive {:compaction_input, "Compact the transcript for this test.", 4, 2}

    assert %Compaction{status: :summarized, summary: "summary from 4 messages"} =
             updated_agent.state[Compaction.state_key()]

    assert get_in(params, [:tool_context, Compaction.context_key(), :summary]) == "summary from 4 messages"

    assert get_in(updated_agent.state, [:requests, "req-compact", :meta, :jidoka_compaction, :status]) ==
             :summarized
  end

  test "automatic compaction skips below-threshold and manual modes without summarizing" do
    runtime = CompactionAgent.runtime_module()

    agent =
      runtime
      |> new_runtime_agent()
      |> put_thread([
        ai_message(:user, "short 1", request_id: "req-1"),
        ai_message(:assistant, "short 2", request_id: "req-1")
      ])

    config = %{CompactionAgent.compaction() | max_messages: 10}

    assert {:ok, updated_agent, {:ai_react_start, params}} =
             Compaction.on_before_cmd(
               agent,
               {:ai_react_start, %{query: "next", request_id: "req-skip", tool_context: %{}}},
               config,
               %{session: "test-session"}
             )

    assert get_in(updated_agent.state, [:requests, "req-skip", :meta, :jidoka_compaction, :status]) == :skipped

    assert get_in(updated_agent.state, [:requests, "req-skip", :meta, :jidoka_compaction, :metadata, :reason]) ==
             :below_threshold

    assert params.tool_context.session == "test-session"

    assert {:ok, manual_agent, {:ai_react_start, manual_params}} =
             Compaction.on_before_cmd(
               agent,
               {:ai_react_start, %{query: "next", request_id: "req-manual", tool_context: %{conversation: "conv"}}},
               %{config | mode: :manual},
               %{}
             )

    assert get_in(manual_agent.state, [:requests, "req-manual", :meta, :jidoka_compaction]) ==
             %{status: :manual, enabled?: true}

    refute Map.has_key?(manual_params.tool_context, Compaction.context_key())

    assert {:ok, ^agent, :noop} = Compaction.on_before_cmd(agent, :noop, config, %{})

    assert {:ok, ^agent, {:ai_react_start, %{}}} =
             Compaction.on_before_cmd(agent, {:ai_react_start, %{}}, %{mode: :off}, %{})

    assert {:ok, ^agent, {:ai_react_start, %{}}} = Compaction.on_before_cmd(agent, {:ai_react_start, %{}}, nil, %{})
  end

  test "automatic compaction fails open when summarization fails" do
    test_pid = self()

    Application.put_env(:jidoka, :compaction_summarizer, fn input ->
      send(test_pid, {:compaction_attempted, input.source_message_count})
      {:unexpected, :summary}
    end)

    runtime = CompactionAgent.runtime_module()

    agent =
      runtime
      |> new_runtime_agent()
      |> put_thread([
        ai_message(:user, "old 1", request_id: "req-1"),
        ai_message(:assistant, "old 2", request_id: "req-1"),
        ai_message(:user, "old 3", request_id: "req-2"),
        ai_message(:assistant, "old 4", request_id: "req-2"),
        ai_message(:user, "recent 1", request_id: "req-3"),
        ai_message(:assistant, "recent 2", request_id: "req-3")
      ])

    result =
      capture_log(fn ->
        send(
          test_pid,
          {:compaction_result,
           Compaction.on_before_cmd(
             agent,
             {:ai_react_start, %{query: "next", request_id: "req-error", tool_context: %{}}},
             CompactionAgent.compaction(),
             %{}
           )}
        )
      end)

    assert result =~ "Jidoka compaction failed"

    assert_receive {:compaction_attempted, 4}
    assert_receive {:compaction_result, {:ok, updated_agent, {:ai_react_start, _params}}}
    assert get_in(updated_agent.state, [:requests, "req-error", :meta, :jidoka_compaction, :status]) == :error
  end

  test "manual compaction updates a running agent snapshot" do
    {:ok, pid} = ManualCompactionAgent.start_link(id: "manual-compaction-test")

    :sys.replace_state(pid, fn state ->
      agent =
        put_thread(state.agent, [
          ai_message(:user, "old manual 1", request_id: "req-1"),
          ai_message(:assistant, "old manual 2", request_id: "req-1"),
          ai_message(:user, "old manual 3", request_id: "req-2"),
          ai_message(:assistant, "old manual 4", request_id: "req-2"),
          ai_message(:user, "recent manual 1", request_id: "req-3"),
          ai_message(:assistant, "recent manual 2", request_id: "req-3")
        ])

      Jido.AgentServer.State.update_agent(state, agent)
    end)

    assert {:ok, %Compaction{status: :summarized, summary: "manual summary"}} =
             Jidoka.compact(pid, summarizer: fn _input -> {:ok, "manual summary"} end)

    assert {:ok, %Compaction{summary: "manual summary"}} = Jidoka.inspect_compaction(pid)

    :ok = Jidoka.stop_agent(pid)
  end

  test "manual compaction validates sessions, config overrides, and summarizer results" do
    session = Jidoka.Session.new!(agent: ManualCompactionAgent, id: "compaction-not-running")

    assert {:error, %Jidoka.Error.ValidationError{} = error} = Jidoka.compact(session)
    assert error.field == :session
    assert error.details.reason == :session_agent_not_running

    agent =
      ChatAgent.runtime_module()
      |> new_runtime_agent()
      |> put_thread([
        ai_message(:user, "source 1", request_id: "req-1"),
        ai_message(:assistant, "source 2", request_id: "req-1"),
        ai_message(:user, "tail 1", request_id: "req-2"),
        ai_message(:assistant, "tail 2", request_id: "req-2")
      ])

    config = %{
      "mode" => "manual",
      "strategy" => "summary",
      "max_messages" => 3,
      "keep_last" => 2,
      "max_summary_chars" => 20
    }

    Code.ensure_loaded!(CompactionSummarizer)

    assert {:ok, %Compaction{status: :summarized, summary: "module summary for 2"}} =
             Jidoka.compact(agent, config: config, summarizer: CompactionSummarizer)

    assert {:error, {:invalid_compaction_summary, %{bad: :summary}}} =
             Jidoka.compact(agent, config: config, summarizer: fn _input -> %{bad: :summary} end)

    assert {:error, :missing_compaction_model} =
             agent
             |> Map.update!(:state, &Map.drop(&1, [:model, :__strategy__]))
             |> Jidoka.compact(config: config)

    assert {:error, %Jidoka.Error.ValidationError{} = error} = Jidoka.compact(agent)
    assert error.field == :compaction
    assert error.details.reason == :compaction_not_configured
  end

  test "request transformer injects compaction summary and trims old messages" do
    compaction = %Compaction{
      id: "compaction-test",
      status: :summarized,
      strategy: :summary,
      summary: "Earlier, the user chose billing triage.",
      summary_preview: "Earlier, the user chose billing triage.",
      source_message_count: 2,
      retained_message_count: 2
    }

    request =
      react_request([
        %{role: :system, content: "old system"},
        %{role: :user, content: "old user"},
        %{role: :assistant, content: "old assistant"},
        %{role: :user, content: "new user"},
        %{role: :assistant, content: "new assistant"}
      ])

    assert {:ok, %{messages: messages}} =
             CompactionAgent.request_transformer().transform_request(
               request,
               react_state(),
               react_config(CompactionAgent.request_transformer()),
               %{
                 Compaction.context_key() => %{
                   compaction: compaction,
                   summary: compaction.summary,
                   keep_last: 2
                 }
               }
             )

    assert [
             %{role: :system, content: system_prompt},
             %{role: :user, content: "new user"},
             %{role: :assistant, content: "new assistant"}
           ] = messages

    assert system_prompt =~ "You have compaction."
    assert system_prompt =~ "Compacted conversation summary:"
    assert system_prompt =~ "Earlier, the user chose billing triage."
    refute Enum.any?(messages, &(Map.get(&1, :content) == "old user"))
  end

  test "memory recall and compaction trimming coexist in the runtime context" do
    compaction = %Compaction{
      id: "memory-compaction-test",
      status: :summarized,
      strategy: :summary,
      summary: "Earlier turns established the user is asking about durable preferences.",
      summary_preview: "Earlier turns established the user is asking about durable preferences.",
      source_message_count: 3,
      retained_message_count: 2
    }

    memory = %{
      namespace: "agent:memory_agent:context:session:memory-compaction",
      records: [
        %{kind: :user_turn, text: "Remember that my favorite color is blue."}
      ],
      prompt: "Relevant memory:\n- User: Remember that my favorite color is blue."
    }

    runtime_context = %{
      Compaction.context_key() => %{
        compaction: compaction,
        summary: compaction.summary,
        keep_last: 2
      },
      Jidoka.Memory.context_key() => memory
    }

    source_messages = [
      %{role: :system, content: "old system"},
      %{role: :user, content: "old preference setup"},
      %{role: :assistant, content: "old preference response"},
      %{role: :user, content: "What is my favorite color?"},
      %{role: :assistant, content: "You said it was blue."}
    ]

    assert Jidoka.Memory.prompt_text(runtime_context) == memory.prompt
    assert Compaction.prompt_text(runtime_context) =~ compaction.summary

    assert [
             %{role: :user, content: "What is my favorite color?"},
             %{role: :assistant, content: "You said it was blue."}
           ] = Compaction.apply_to_messages(source_messages, runtime_context)

    assert Enum.map(source_messages, & &1.content) == [
             "old system",
             "old preference setup",
             "old preference response",
             "What is my favorite color?",
             "You said it was blue."
           ]

    assert {:ok, %{messages: messages}} =
             CompactionAgent.request_transformer().transform_request(
               react_request(source_messages),
               react_state(),
               react_config(CompactionAgent.request_transformer()),
               runtime_context
             )

    assert [
             %{role: :system, content: system_prompt},
             %{role: :user, content: "What is my favorite color?"},
             %{role: :assistant, content: "You said it was blue."}
           ] = messages

    assert system_prompt =~ "Compacted conversation summary:"
    assert system_prompt =~ "Earlier turns established the user is asking about durable preferences."
    assert system_prompt =~ "Relevant memory:"
    assert system_prompt =~ "favorite color is blue"
    refute Enum.any?(messages, &(Map.get(&1, :content) == "old preference setup"))
  end

  test "message trimming preserves tool call and tool result adjacency" do
    context = %{
      Compaction.context_key() => %{
        summary: "tool context exists",
        keep_last: 3
      }
    }

    messages = [
      %{role: :user, content: "old"},
      %{role: :assistant, content: "", tool_calls: [%{id: "call-1", name: "lookup"}]},
      %{role: :tool, content: "result", tool_call_id: "call-1"},
      %{role: :assistant, content: "used result"},
      %{role: :user, content: "next"}
    ]

    assert [
             %{role: :assistant, tool_calls: [_]},
             %{role: :tool, tool_call_id: "call-1"},
             %{role: :assistant, content: "used result"},
             %{role: :user, content: "next"}
           ] = Compaction.apply_to_messages(messages, context)
  end

  test "imported specs round-trip compaction through JSON and YAML" do
    spec = %{
      "agent" => %{"id" => "imported_compaction_agent"},
      "defaults" => %{"model" => "fast", "instructions" => "Use compact context."},
      "lifecycle" => %{
        "compaction" => %{
          "mode" => "auto",
          "strategy" => "summary",
          "max_messages" => 10,
          "keep_last" => 4,
          "max_summary_chars" => 500,
          "prompt" => "Imported compaction prompt."
        }
      }
    }

    assert {:ok, %ImportedAgent{} = agent} = Jidoka.import_agent(spec)
    assert %{mode: :auto, keep_last: 4, prompt: "Imported compaction prompt."} = agent.spec.compaction

    assert {:ok, encoded_json} = Jidoka.encode_agent(agent, format: :json)
    assert encoded_json =~ "\"compaction\""

    assert {:ok, encoded_yaml} = Jidoka.encode_agent(agent, format: :yaml)
    assert encoded_yaml =~ "compaction:"
    assert encoded_yaml =~ "Imported compaction prompt."

    assert {:ok, %ImportedAgent{} = yaml_agent} = Jidoka.import_agent(encoded_yaml, format: :yaml)
    assert %{mode: :auto, keep_last: 4, prompt: "Imported compaction prompt."} = yaml_agent.spec.compaction
  end

  defp put_thread(agent, entries) do
    ThreadAgent.put(agent, Thread.new(id: "thread-compaction") |> Thread.append(entries))
  end

  defp ai_message(role, content, attrs) do
    payload =
      attrs
      |> Map.new()
      |> Map.merge(%{role: role, content: content, context_ref: Keyword.get(attrs, :context_ref, "default")})

    %{
      kind: :ai_message,
      payload: payload,
      refs: %{request_id: Map.get(payload, :request_id)}
    }
  end
end
