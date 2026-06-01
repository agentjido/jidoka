defmodule JidokaExample.KitchenSinkSupport do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Turn
  alias JidokaExample.AshAgent.Domain
  alias JidokaExample.KitchenSinkAgent.Agent
  alias JidokaExample.KitchenSinkAgent.MCP.LocalClient
  alias JidokaExample.MemoryAgent.Memory

  @browser_env_keys [
    :browser_actions,
    :browser_max_results,
    :browser_max_content_chars,
    :dns_resolver
  ]

  def setup do
    conversation_id = "kitchen-flow-#{System.unique_integer([:positive])}"

    reset_shared_state!(conversation_id)
    install_fake_browser!()

    {:ok,
     conversation_id: conversation_id,
     context: context(conversation_id),
     memory_store: Memory.store()}
  end

  def reset_shared_state!(conversation_id) do
    Memory.ensure_ready!()
    clear_table(:jidoka_example_memory)
    clear_table(:jidoka_example_customers)
    Jidoka.reset_handoff(conversation_id)
  end

  def install_fake_browser! do
    previous =
      Map.new(@browser_env_keys, fn key ->
        {key, Application.fetch_env(:jidoka, key)}
      end)

    Application.put_env(:jidoka, :browser_actions, %{
      search_web: __MODULE__.FakeSearchWeb,
      read_page: __MODULE__.FakeReadPage,
      snapshot_url: __MODULE__.FakeSnapshotUrl
    })

    Application.put_env(:jidoka, :browser_max_results, 5)
    Application.put_env(:jidoka, :browser_max_content_chars, 700)

    Application.put_env(:jidoka, :dns_resolver, fn _host, _family ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:jidoka, key, value)
        {key, :error} -> Application.delete_env(:jidoka, key)
      end)
    end)
  end

  def context(conversation_id, overrides \\ %{}) do
    Map.merge(
      %{
        tenant: "demo",
        channel: "test",
        session_id: conversation_id,
        surface: "ex_unit",
        example: "kitchen_sink_agent",
        actor: %{id: "test-developer", role: "developer"}
      },
      overrides
    )
  end

  def request(input, context) when is_binary(input) and is_map(context) do
    Turn.Request.new!(input: input, context: context)
  end

  def agent_run_opts(llm, context, memory_store, extra_context \\ %{}) do
    [
      llm: llm,
      memory_store: memory_store,
      operation_context:
        operation_context(context, llm, Map.put(extra_context, :memory_store, memory_store))
    ]
  end

  def session_run_opts(llm, context, memory_store, extra_context \\ %{}) do
    [
      llm: llm,
      operations:
        operation_capability(context, llm, Map.put(extra_context, :memory_store, memory_store)),
      memory_store: memory_store
    ]
  end

  def resume_opts(llm, context, extra_context \\ %{}) do
    [
      llm: llm,
      operations: operation_capability(context, llm, extra_context)
    ]
  end

  def operation_capability(context, llm, extra_context \\ %{}) do
    Jidoka.Agent.ToolSources.operation_capability(Agent,
      context:
        context
        |> operation_context(llm, extra_context)
        |> Map.merge(%{
          agent_module: Agent,
          jido_agent: Agent.new(),
          jidoka_spec: Agent.spec()
        })
    )
  end

  def operation_context(context, llm, extra_context \\ %{}) do
    Map.merge(
      %{
        domain: Domain,
        mcp_client: LocalClient,
        memory_store: Memory.store(),
        parent_context: context,
        subagent_llm: llm
      },
      Map.merge(context, extra_context)
    )
  end

  def count_results(%Effect.Journal{results: results}, kind) do
    results
    |> Map.values()
    |> Enum.count(&(&1.kind == kind))
  end

  def operation_outputs(%Turn.Result{} = result) do
    Map.new(result.agent_state.operation_results, &{&1.operation, &1.output})
  end

  def operation_names(%Turn.Result{} = result) do
    Enum.map(result.agent_state.operation_results, & &1.operation)
  end

  def get(map, key, default \\ nil)

  def get(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  def get(_map, _key, default), do: default

  def valid_result(summary, features) do
    %{
      summary: summary,
      features: Enum.map(features, &%{name: &1, evidence: "#{&1} returned observable data"}),
      sources: [],
      next_steps: ["Inspect operation results."]
    }
  end

  def memory_message?(messages, expected) do
    Enum.any?(messages, fn message ->
      content = Map.get(message, :content) || Map.get(message, "content") || ""
      String.contains?(content, expected)
    end)
  end

  def prompt_messages(%Effect.Intent{payload: payload}) do
    payload
    |> Jidoka.Schema.get_key(:prompt)
    |> Jidoka.Schema.get_key(:messages, [])
  end

  def message_with_content?(messages, content) do
    Enum.any?(messages, &(Map.get(&1, :content) == content || Map.get(&1, "content") == content))
  end

  def tool_observation?(messages, operation, expected_fragment) do
    Enum.any?(messages, fn message ->
      observed_operation = Map.get(message, :operation) || Map.get(message, "operation")
      output = Map.get(message, :output) || Map.get(message, "output") || %{}

      observed_operation == operation and output_contains?(output, expected_fragment)
    end)
  end

  defp clear_table(table) do
    case :ets.whereis(table) do
      :undefined -> :ok
      _tid -> :ets.delete_all_objects(table)
    end
  end

  defp output_contains?(output, expected_fragment) when is_binary(expected_fragment) do
    output
    |> inspect()
    |> String.contains?(expected_fragment)
  end

  defmodule FakeSearchWeb do
    @moduledoc false

    def run(params, _context) do
      query = Map.get(params, :query, Map.get(params, "query"))

      {:ok,
       %{
         query: query,
         count: 2,
         results: [
           %{
             title: "Runic Workflows",
             url: "https://example.com/runic-workflows",
             snippet: "Runic composes workflow steps as explicit runtime data."
           },
           %{
             title: "Jidoka Agent Harness",
             url: "https://example.com/jidoka-harness",
             snippet: "Jidoka uses a Runic-backed turn spine for deterministic effects."
           }
         ]
       }}
    end
  end

  defmodule FakeReadPage do
    @moduledoc false

    def run(params, _context) do
      url = Map.get(params, :url, Map.get(params, "url"))

      {:ok,
       %{
         title: "Runic Workflows",
         url: url,
         content:
           "Runic workflows model agent execution as inspectable steps with explicit effect boundaries."
       }}
    end
  end

  defmodule FakeSnapshotUrl do
    @moduledoc false

    def run(params, _context) do
      {:ok,
       %{
         title: "Snapshot",
         url: Map.get(params, :url, Map.get(params, "url")),
         image: "data:image/png;base64,ZmFrZQ=="
       }}
    end
  end
end
