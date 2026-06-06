defmodule Jidoka.Agent.ToolSources.MCP do
  @moduledoc false

  alias Jidoka.Agent.Dsl.MCPTools
  alias Jidoka.Agent.ToolSources.Common
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.MCP, as: MCPSource

  @spec source!(term()) :: MCPSource.t()
  def source!(%MCPTools{} = mcp_tools) do
    MCPSource.new!(
      endpoint: mcp_tools.endpoint,
      prefix: mcp_tools.prefix,
      tools: mcp_tools.tools || [],
      required: mcp_tools.required || false,
      transport: mcp_tools.transport,
      client_info: mcp_tools.client_info,
      protocol_version: mcp_tools.protocol_version,
      capabilities: mcp_tools.capabilities || %{},
      timeouts: mcp_tools.timeouts || %{},
      timeout: mcp_tools.timeout,
      description: mcp_tools.description,
      idempotency: mcp_tools.idempotency || :idempotent,
      metadata: mcp_tools.metadata || %{}
    )
  end

  @spec operations!(term()) :: [Jidoka.Agent.Spec.Operation.t()]
  def operations!(%MCPTools{} = mcp_tools) do
    mcp_tools
    |> source!()
    |> Source.operations()
    |> case do
      {:ok, operations} -> operations
      {:error, reason} -> raise ArgumentError, "invalid MCP source: #{inspect(reason)}"
    end
  end

  @spec metadata!(term()) :: [map()]
  def metadata!(%MCPTools{} = mcp_tools) do
    source = source!(mcp_tools)

    [
      %{
        "source" => "mcp",
        "endpoint" => Common.metadata_value(source.endpoint),
        "prefix" => source.prefix,
        "required" => source.required,
        "transport" => Common.metadata_value(source.transport),
        "client_info" => source.client_info,
        "protocol_version" => source.protocol_version,
        "capabilities" => source.capabilities,
        "timeouts" => source.timeouts,
        "tools" => Enum.map(source.tools, & &1.name)
      }
      |> Common.reject_nil_values()
    ]
  end
end
