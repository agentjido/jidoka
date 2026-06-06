defmodule Jidoka.Operation.Source.MCP.Tools do
  @moduledoc false

  alias Jidoka.Schema

  @spec normalize_static(term()) :: {:ok, [map()]} | {:error, term()}
  def normalize_static(tools) when is_list(tools) do
    tools
    |> Enum.reduce_while({:ok, []}, fn tool, {:ok, acc} ->
      case normalize_tool(tool) do
        {:ok, tool} -> {:cont, {:ok, acc ++ [tool]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_static(tools), do: {:error, {:invalid_mcp_tools, tools}}

  @spec normalize_list_tools_response(term()) :: {:ok, [map()]} | {:error, term()}
  def normalize_list_tools_response({:ok, %{data: data}}),
    do: normalize_list_tools_response({:ok, data})

  def normalize_list_tools_response({:ok, data}) do
    data
    |> extract_tools()
    |> normalize_static()
  end

  def normalize_list_tools_response({:error, reason}), do: {:error, reason}
  def normalize_list_tools_response(other), do: {:error, {:invalid_mcp_tools_response, other}}

  defp extract_tools(data) when is_list(data), do: data

  defp extract_tools(data) when is_map(data) do
    Schema.get_key(data, :tools, [])
  end

  defp extract_tools(_data), do: []

  defp normalize_tool(tool) when is_map(tool) do
    with {:ok, name} <- normalize_remote_name(Schema.get_key(tool, :name)),
         {:ok, input_schema} <- normalize_input_schema(tool) do
      {:ok,
       %{
         name: name,
         description: Schema.get_key(tool, :description),
         input_schema: input_schema
       }}
    end
  end

  defp normalize_tool(tool), do: {:error, {:invalid_mcp_tool, tool}}

  defp normalize_input_schema(tool) do
    schema =
      Schema.get_key(tool, :input_schema) ||
        Schema.get_key(tool, :inputSchema) ||
        Schema.get_key(tool, :parameters_schema) ||
        Schema.get_key(tool, :schema)

    cond do
      is_nil(schema) -> {:ok, nil}
      is_map(schema) -> {:ok, schema}
      true -> {:error, {:invalid_mcp_tool_schema, schema}}
    end
  end

  defp normalize_remote_name(name) when is_atom(name) and not is_nil(name) do
    name |> Atom.to_string() |> normalize_remote_name()
  end

  defp normalize_remote_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, {:invalid_mcp_tool_name, name}}
      name -> {:ok, name}
    end
  end

  defp normalize_remote_name(name), do: {:error, {:invalid_mcp_tool_name, name}}
end
