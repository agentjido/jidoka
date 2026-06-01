defmodule Jidoka.MCPTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.MCP
  alias Jidoka.Turn

  defmodule FakeMCPClient do
    @moduledoc false

    def list_tools(:demo_mcp, _opts) do
      {:ok,
       %{
         data: %{
           "tools" => [
             %{
               "name" => "lookup_policy",
               "description" => "Looks up a policy in a fake MCP server.",
               "inputSchema" => %{
                 "type" => "object",
                 "properties" => %{"topic" => %{"type" => "string"}}
               }
             }
           ]
         }
       }}
    end

    def list_tools(:list_response, _opts) do
      {:ok,
       [
         %{
           name: "Remote Tool",
           description: "Uses default prefix and operation slug.",
           schema: %{"type" => "object"}
         }
       ]}
    end

    def list_tools(:bad_list_response, _opts), do: :bad_response

    def call_tool(:demo_mcp, "lookup_policy", args, _opts) do
      {:ok, %{data: %{"topic" => args["topic"], "policy" => "Use MCP through Jidoka."}}}
    end

    def call_tool(:list_response, "Remote Tool", _args, _opts), do: {:ok, %{ok: true}}

    def call_tool(:bad_call_response, "broken", _args, _opts), do: :bad_response
  end

  defmodule StaticMCPAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :static_mcp_agent do
      model %{provider: :test, id: "model"}
      instructions "Use the MCP policy tool when asked about policy."
    end

    tools do
      mcp_tools endpoint: :demo_mcp,
                prefix: "mcp_",
                tools: [
                  %{
                    name: "lookup_policy",
                    description: "Looks up a policy in a fake MCP server.",
                    input_schema: %{
                      "type" => "object",
                      "properties" => %{"topic" => %{"type" => "string"}}
                    }
                  }
                ]
    end
  end

  test "MCP sources discover operations and call tools through a client" do
    source =
      MCP.new!(
        endpoint: :demo_mcp,
        prefix: "mcp_",
        client: FakeMCPClient
      )

    assert {:ok, [%Operation{name: "mcp_lookup_policy"} = operation]} =
             Source.operations(source)

    assert Operation.kind(operation) == :mcp
    assert operation.metadata["source"] == "mcp"
    assert operation.metadata["remote_tool"] == "lookup_policy"
    assert operation.metadata["parameters_schema"]["type"] == "object"

    assert {:ok, %{capability: capability}} =
             Source.compile(source, context: %{mcp_client: FakeMCPClient})

    intent =
      Effect.Intent.new(:operation, %{
        name: "mcp_lookup_policy",
        arguments: %{"topic" => "runtime"}
      })

    assert {:ok,
            %{
              endpoint: "demo_mcp",
              tool: "lookup_policy",
              result: %{"policy" => "Use MCP through Jidoka.", "topic" => "runtime"}
            }} = capability.(intent, Effect.Journal.new!())
  end

  test "MCP sources normalize defaults, runtime client overrides, and malformed responses" do
    source =
      MCP.new!(
        endpoint: :list_response,
        client: String,
        timeout: 123,
        idempotency: "pure",
        metadata: %{"owner" => "tests"}
      )

    assert {:ok, [%Operation{name: "mcp_list_response_remote__tool"} = operation]} =
             Source.operations(source, context: %{mcp_client: FakeMCPClient})

    assert operation.idempotency == :pure
    assert operation.metadata["owner"] == "tests"
    assert operation.metadata["endpoint"] == "list_response"

    assert {:ok, %{capability: capability}} =
             Source.compile(source, context: %{mcp_client: FakeMCPClient})

    intent =
      Effect.Intent.new(:operation, %{
        name: "mcp_list_response_remote__tool",
        arguments: %{}
      })

    assert {:ok, %{endpoint: "list_response", tool: "Remote Tool", result: %{ok: true}}} =
             capability.(intent, Effect.Journal.new!())

    bad_list = MCP.new!(endpoint: :bad_list_response, client: FakeMCPClient, required: true)

    assert {:error,
            {:mcp_tool_discovery_failed, :bad_list_response,
             {:invalid_mcp_tools_response, :bad_response}}} = Source.operations(bad_list)

    bad_call =
      MCP.new!(
        endpoint: :bad_call_response,
        client: FakeMCPClient,
        tools: [%{name: "broken"}]
      )

    assert {:ok, %{capability: bad_call_capability}} = Source.compile(bad_call)

    bad_intent = Effect.Intent.new(:operation, %{name: "mcp_bad_call_response_broken"})

    assert {:error, {:invalid_mcp_call_response, :bad_response}} =
             bad_call_capability.(bad_intent, Effect.Journal.new!())
  end

  test "MCP tools declared in the DSL execute through the normal operation loop" do
    llm = fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "mcp_lookup_policy",
             arguments: %{"topic" => "agent"}
           }}

        1 ->
          {:ok, %{type: :final, content: "The MCP policy was returned."}}
      end
    end

    assert [%Operation{name: "mcp_lookup_policy"} = operation] = StaticMCPAgent.spec().operations
    assert Operation.kind(operation) == :mcp

    assert {:ok, %Turn.Result{} = result} =
             StaticMCPAgent.run_turn("What is the MCP policy?",
               llm: llm,
               operation_context: %{mcp_client: FakeMCPClient}
             )

    assert result.content == "The MCP policy was returned."

    assert [
             %Effect.OperationResult{
               operation: "mcp_lookup_policy",
               output: %{result: %{"policy" => "Use MCP through Jidoka."}}
             }
           ] = result.agent_state.operation_results
  end

  test "optional MCP discovery is fail-open while required discovery is fail-closed" do
    optional = MCP.new!(endpoint: :missing, client: String)
    assert {:ok, []} = Source.operations(optional)

    required = MCP.new!(endpoint: :missing, client: String, required: true)

    assert {:error, {:mcp_tool_discovery_failed, :missing, {:invalid_mcp_client, String}}} =
             Source.operations(required)
  end

  test "MCP source validates malformed configuration" do
    assert {:error, {:invalid_mcp_endpoint, ""}} = MCP.new(endpoint: "")
    assert {:error, {:invalid_mcp_prefix, ""}} = MCP.new(endpoint: :demo, prefix: "")
    assert {:error, {:invalid_mcp_tools, :bad}} = MCP.new(endpoint: :demo, tools: :bad)
    assert {:error, {:invalid_mcp_tool, :bad}} = MCP.new(endpoint: :demo, tools: [:bad])

    assert {:error, {:invalid_mcp_tool_schema, :bad}} =
             MCP.new(endpoint: :demo, tools: [%{name: "lookup", input_schema: :bad}])

    assert {:error, {:invalid_mcp_required, :yes}} = MCP.new(endpoint: :demo, required: :yes)
    assert {:error, {:invalid_mcp_timeout, 0}} = MCP.new(endpoint: :demo, timeout: 0)

    assert {:error, {:invalid_mcp_idempotency, "eventual"}} =
             MCP.new(endpoint: :demo, idempotency: "eventual")

    assert {:error, {:invalid_mcp_metadata, []}} = MCP.new(endpoint: :demo, metadata: [])
    assert {:error, {:invalid_mcp_client, "client"}} = MCP.new(endpoint: :demo, client: "client")

    assert_raise ArgumentError, ~r/invalid MCP source/, fn ->
      MCP.new!(endpoint: "")
    end
  end

  defp count_results(%Effect.Journal{results: results}, kind) do
    results
    |> Map.values()
    |> Enum.count(&(&1.kind == kind))
  end
end
