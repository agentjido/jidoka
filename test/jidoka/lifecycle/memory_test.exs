defmodule JidokaTest.MemoryTest do
  use JidokaTest.Support.Case, async: false

  alias Jidoka.Agent.Dsl.{
    MemoryCapture,
    MemoryInject,
    MemoryMode,
    MemoryNamespace,
    MemoryRetrieve,
    MemorySharedNamespace
  }

  alias JidokaTest.MemoryAgent

  defmodule QueryFailureStore do
    @behaviour Jido.Memory.Store

    def validate_options(_opts), do: :ok
    def ensure_ready(_opts), do: :ok
    def put(record, _opts), do: {:ok, record}
    def get(_key, _opts), do: :not_found
    def delete(_key, _opts), do: :ok
    def query(_query, _opts), do: {:error, :query_failed}
    def prune_expired(_opts), do: {:ok, 0}
  end

  defmodule CaptureFailureStore do
    @behaviour Jido.Memory.Store

    def validate_options(_opts), do: :ok
    def ensure_ready(_opts), do: :ok
    def put(_record, _opts), do: {:error, :put_failed}
    def get(_key, _opts), do: :not_found
    def delete(_key, _opts), do: :ok
    def query(_query, _opts), do: {:ok, []}
    def prune_expired(_opts), do: {:ok, 0}
  end

  defmodule SecretMemoryStore do
    @behaviour Jido.Memory.Store

    @secret "sk-ant-secret12345678901234567890"

    def validate_options(_opts), do: :ok
    def ensure_ready(_opts), do: :ok
    def put(record, _opts), do: {:ok, record}
    def get(_key, _opts), do: :not_found
    def delete(_key, _opts), do: :ok

    def query(_query, _opts) do
      {:ok,
       [
         Jido.Memory.Record.new!(%{
           namespace: "agent:memory_agent:context:session:redaction",
           class: :episodic,
           kind: :user_turn,
           text: "The recalled note has api_key=#{@secret}.",
           content: %{message: "The recalled note has api_key=#{@secret}."}
         })
       ]}
    end

    def prune_expired(_opts), do: {:ok, 0}
  end

  test "normalizes DSL memory entries, defaults, and duplicate entries" do
    assert Jidoka.Memory.normalize_dsl([]) == {:ok, nil}

    assert {:ok,
            %{
              mode: :conversation,
              namespace: {:shared, "team"},
              capture: :off,
              retrieve: %{limit: 2},
              inject: :context
            }} =
             Jidoka.Memory.normalize_dsl([
               %MemoryMode{value: :conversation},
               %MemoryNamespace{value: :shared},
               %MemorySharedNamespace{value: " team "},
               %MemoryCapture{value: :off},
               %MemoryRetrieve{limit: 2},
               %MemoryInject{value: :context}
             ])

    assert {:error, reason} =
             Jidoka.Memory.normalize_dsl([
               %MemoryMode{value: :conversation},
               %MemoryMode{value: :conversation}
             ])

    assert reason =~ "duplicate memory mode entry"
  end

  test "validates imported memory defaults and known string values without atom leaks" do
    assert {:ok, default} = Jidoka.Memory.normalize_imported(%{})
    assert default == Jidoka.Memory.default_config()

    assert {:ok,
            %{
              namespace: {:shared, "team"},
              capture: :off,
              retrieve: %{limit: 3},
              inject: :context
            }} =
             Jidoka.Memory.normalize_imported(%{
               "mode" => "conversation",
               "namespace" => "shared",
               "shared_namespace" => " team ",
               "capture" => "off",
               "retrieve" => %{"limit" => 3},
               "inject" => "context"
             })

    unsupported_mode = "unknown-memory-mode-#{System.unique_integer([:positive])}"
    assert {:error, reason} = Jidoka.Memory.normalize_imported(%{"mode" => unsupported_mode})
    assert reason =~ "memory mode must be :conversation"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unsupported_mode) end
  end

  test "validates imported memory namespace combinations" do
    assert {:error, reason} =
             Jidoka.Memory.normalize_imported(%{
               "namespace" => "shared",
               "shared_namespace" => " "
             })

    assert reason =~ "memory namespace must be :per_agent, :shared with shared_namespace"

    assert {:error, reason} =
             Jidoka.Memory.normalize_imported(%{
               "namespace" => "context"
             })

    assert reason =~ "memory namespace must be :per_agent, :shared, or {:context, key}"

    assert {:error, reason} =
             Jidoka.Memory.normalize_imported(%{
               "retrieve" => %{"limit" => 0}
             })

    assert reason =~ "memory retrieve limit must be a positive integer"
  end

  test "builds memory plugin configs for disabled, per-agent, shared, and context namespaces" do
    assert Jidoka.Memory.default_plugins(nil) == %{__memory__: false}

    assert %{__memory__: {Jido.Memory.BasicPlugin, per_agent}} =
             Jidoka.Memory.default_plugins(Jidoka.Memory.default_config())

    assert per_agent.namespace_mode == :per_agent
    assert per_agent.auto_capture == false

    assert {:ok, shared} =
             Jidoka.Memory.normalize_imported(%{
               "mode" => "conversation",
               "namespace" => "shared",
               "shared_namespace" => "shared-team"
             })

    assert %{__memory__: {Jido.Memory.BasicPlugin, shared_plugin}} = Jidoka.Memory.default_plugins(shared)
    assert shared_plugin.namespace_mode == :shared
    assert shared_plugin.shared_namespace == "shared-team"

    assert {:ok, context} =
             Jidoka.Memory.normalize_imported(%{
               "mode" => "conversation",
               "namespace" => "context",
               "context_namespace_key" => "session"
             })

    assert %{__memory__: {Jido.Memory.BasicPlugin, context_plugin}} = Jidoka.Memory.default_plugins(context)
    assert context_plugin.namespace_mode == :per_agent
  end

  test "returns a structured memory failure when context namespace key is missing" do
    runtime = MemoryAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    assert {:ok, failed_agent, {:ai_react_request_error, error_action}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start, %{query: "remember this", request_id: "req-memory-missing-context"}}
             )

    assert error_action.reason == :memory_failed

    assert %Jidoka.Error.ValidationError{} =
             get_in(failed_agent.state, [
               :requests,
               "req-memory-missing-context",
               :meta,
               :jidoka_memory,
               :error
             ])
  end

  test "records memory retrieval failures on request metadata" do
    runtime = MemoryAgent.runtime_module()
    agent = runtime |> new_runtime_agent() |> put_memory_store(QueryFailureStore)

    assert {:ok, failed_agent, {:ai_react_request_error, error_action}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start,
                %{
                  query: "remember this",
                  request_id: "req-memory-query-failure",
                  tool_context: %{session: "query-failure"}
                }}
             )

    assert error_action.reason == :memory_failed

    assert %Jidoka.Error.ExecutionError{phase: :memory} =
             get_in(failed_agent.state, [
               :requests,
               "req-memory-query-failure",
               :meta,
               :jidoka_memory,
               :error
             ])
  end

  test "records memory capture failures without failing the completed request" do
    runtime = MemoryAgent.runtime_module()
    agent = runtime |> new_runtime_agent() |> put_memory_store(CaptureFailureStore)

    assert {:ok, agent, _action} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start,
                %{
                  query: "remember this",
                  request_id: "req-memory-capture-failure",
                  tool_context: %{session: "capture-failure"}
                }}
             )

    agent = Jido.AI.Request.complete_request(agent, "req-memory-capture-failure", "stored")

    assert {:ok, agent, []} =
             runtime.on_after_cmd(
               agent,
               {:ai_react_start, %{request_id: "req-memory-capture-failure"}},
               []
             )

    memory_meta = get_in(agent.state, [:requests, "req-memory-capture-failure", :meta, :jidoka_memory])
    assert memory_meta.captured? == false
    assert %Jidoka.Error.ExecutionError{phase: :memory} = memory_meta.capture_error
  end

  test "extracts memory prompt text from runtime context" do
    assert Jidoka.Memory.prompt_text(%{}) == nil

    assert Jidoka.Memory.prompt_text(%{
             Jidoka.Memory.context_key() => %{prompt: "Relevant memory:\n- User: hello"}
           }) == "Relevant memory:\n- User: hello"
  end

  test "redacts recalled memory in prompt text and request metadata" do
    runtime = MemoryAgent.runtime_module()
    agent = runtime |> new_runtime_agent() |> put_memory_store(SecretMemoryStore)

    assert {:ok, agent, {:ai_react_start, params}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start,
                %{
                  query: "What do you remember?",
                  request_id: "req-memory-redaction",
                  tool_context: %{session: "redaction"}
                }}
             )

    prompt = Jidoka.Memory.prompt_text(params.runtime_context)
    memory_meta = get_in(agent.state, [:requests, "req-memory-redaction", :meta, :jidoka_memory])
    rendered = inspect({prompt, memory_meta})

    assert prompt =~ "api_key=[REDACTED]"
    refute rendered =~ "sk-ant-secret"
  end

  defp put_memory_store(agent, store_module) do
    state =
      put_in(
        agent.state,
        [
          Jido.Memory.Runtime.plugin_state_key(),
          :store
        ],
        {store_module, []}
      )

    %{agent | state: state}
  end
end
