defmodule Jidoka.Operation.Source.MCP do
  @moduledoc """
  Operation source backed by `jido_mcp`.

  MCP tools are normalized into ordinary Jidoka operations. At runtime the
  operation source routes the local operation name back to the remote MCP tool
  name and calls the configured endpoint through `Jido.MCP`.
  """

  @behaviour Jidoka.Operation.Source

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Schema

  @type tool_spec :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:input_schema) => map()
        }

  @type t :: %__MODULE__{
          endpoint: atom() | String.t(),
          prefix: String.t() | nil,
          tools: [tool_spec()],
          required: boolean(),
          timeout: pos_integer() | nil,
          description: String.t() | nil,
          idempotency: Operation.idempotency(),
          metadata: map(),
          client: module()
        }

  defstruct [
    :endpoint,
    :prefix,
    tools: [],
    required: false,
    timeout: nil,
    description: nil,
    idempotency: :idempotent,
    metadata: %{},
    client: Jido.MCP
  ]

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, endpoint} <- normalize_endpoint(Schema.get_key(attrs, :endpoint)),
         {:ok, prefix} <- normalize_prefix(Schema.get_key(attrs, :prefix)),
         {:ok, tools} <- normalize_static_tools(Schema.get_key(attrs, :tools, [])),
         {:ok, required} <- normalize_required(Schema.get_key(attrs, :required, false)),
         {:ok, timeout} <- normalize_timeout(Schema.get_key(attrs, :timeout)),
         {:ok, idempotency} <-
           normalize_idempotency(Schema.get_key(attrs, :idempotency, :idempotent)),
         {:ok, metadata} <- normalize_metadata(Schema.get_key(attrs, :metadata, %{})),
         {:ok, client} <- normalize_client(Schema.get_key(attrs, :client, Jido.MCP)) do
      {:ok,
       %__MODULE__{
         endpoint: endpoint,
         prefix: prefix,
         tools: tools,
         required: required,
         timeout: timeout,
         description: Schema.get_key(attrs, :description),
         idempotency: idempotency,
         metadata: metadata,
         client: client
       }}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, source} -> source
      {:error, reason} -> raise ArgumentError, "invalid MCP source: #{inspect(reason)}"
    end
  end

  @impl true
  def operations(%__MODULE__{} = source, opts) do
    with {:ok, tools} <- tools(source, opts) do
      {:ok, Enum.map(tools, &operation(source, &1))}
    end
  end

  @impl true
  def capability(%__MODULE__{} = source, opts) do
    with {:ok, tools} <- tools(source, opts) do
      routes = Map.new(tools, &{operation_name(source, &1.name), &1.name})
      client = client(source, opts)

      {:ok,
       fn
         %Effect.Intent{kind: :operation, payload: payload}, %Effect.Journal{} ->
           with {:ok, request} <- Effect.OperationRequest.from_input(payload),
                {:ok, remote_name} <- fetch_remote_tool(routes, request.name) do
             call_tool(client, source, remote_name, request.arguments, call_opts(source))
           end

         %Effect.Intent{kind: kind}, _journal ->
           {:error, {:unsupported_effect_kind, kind}}
       end}
    end
  end

  defp operation(%__MODULE__{} = source, %{name: remote_name} = tool) do
    Operation.new!(
      name: operation_name(source, remote_name),
      description: source.description || tool.description || "Call MCP tool #{remote_name}.",
      idempotency: source.idempotency,
      metadata:
        source.metadata
        |> Map.merge(%{
          "source" => "mcp",
          "kind" => "mcp",
          "endpoint" => metadata_value(source.endpoint),
          "remote_tool" => remote_name,
          "prefix" => source.prefix,
          "parameters_schema" => tool.input_schema
        })
        |> reject_nil_values()
    )
  end

  defp tools(%__MODULE__{tools: [_ | _] = tools}, _opts), do: {:ok, tools}

  defp tools(%__MODULE__{} = source, opts) do
    case list_tools(client(source, opts), source, call_opts(source)) do
      {:ok, tools} ->
        {:ok, tools}

      {:error, reason} ->
        if source.required do
          {:error, {:mcp_tool_discovery_failed, source.endpoint, reason}}
        else
          {:ok, []}
        end
    end
  end

  defp list_tools(client, %__MODULE__{} = source, opts) do
    if ensure_client_function?(client, :list_tools, 2) do
      client
      |> apply(:list_tools, [source.endpoint, opts])
      |> normalize_list_tools_response()
    else
      {:error, {:invalid_mcp_client, client}}
    end
  rescue
    exception -> {:error, exception}
  end

  defp call_tool(client, %__MODULE__{} = source, remote_name, arguments, opts) do
    if ensure_client_function?(client, :call_tool, 4) do
      client
      |> apply(:call_tool, [source.endpoint, remote_name, arguments, opts])
      |> normalize_call_tool_response(source, remote_name)
    else
      {:error, {:invalid_mcp_client, client}}
    end
  rescue
    exception -> {:error, exception}
  end

  defp ensure_client_function?(client, function, arity) when is_atom(client) do
    Code.ensure_loaded?(client) and function_exported?(client, function, arity)
  end

  defp normalize_list_tools_response({:ok, %{data: data}}),
    do: normalize_list_tools_response({:ok, data})

  defp normalize_list_tools_response({:ok, data}) do
    data
    |> extract_tools()
    |> normalize_static_tools()
  end

  defp normalize_list_tools_response({:error, reason}), do: {:error, reason}
  defp normalize_list_tools_response(other), do: {:error, {:invalid_mcp_tools_response, other}}

  defp normalize_call_tool_response({:ok, %{data: data}}, source, remote_name) do
    {:ok,
     %{
       endpoint: metadata_value(source.endpoint),
       tool: remote_name,
       result: data
     }}
  end

  defp normalize_call_tool_response({:ok, data}, source, remote_name) do
    {:ok,
     %{
       endpoint: metadata_value(source.endpoint),
       tool: remote_name,
       result: data
     }}
  end

  defp normalize_call_tool_response({:error, reason}, _source, _remote_name), do: {:error, reason}

  defp normalize_call_tool_response(other, _source, _remote_name),
    do: {:error, {:invalid_mcp_call_response, other}}

  defp extract_tools(data) when is_list(data), do: data

  defp extract_tools(data) when is_map(data) do
    Schema.get_key(data, :tools, [])
  end

  defp extract_tools(_data), do: []

  defp normalize_static_tools(tools) when is_list(tools) do
    tools
    |> Enum.reduce_while({:ok, []}, fn tool, {:ok, acc} ->
      case normalize_tool(tool) do
        {:ok, tool} -> {:cont, {:ok, acc ++ [tool]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_static_tools(tools), do: {:error, {:invalid_mcp_tools, tools}}

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

  defp normalize_endpoint(endpoint) when is_atom(endpoint) and not is_nil(endpoint),
    do: {:ok, endpoint}

  defp normalize_endpoint(endpoint) when is_binary(endpoint) do
    case String.trim(endpoint) do
      "" -> {:error, {:invalid_mcp_endpoint, endpoint}}
      endpoint -> {:ok, endpoint}
    end
  end

  defp normalize_endpoint(endpoint), do: {:error, {:invalid_mcp_endpoint, endpoint}}

  defp normalize_prefix(nil), do: {:ok, nil}

  defp normalize_prefix(prefix) when is_binary(prefix) do
    if String.trim(prefix) == "" do
      {:error, {:invalid_mcp_prefix, prefix}}
    else
      {:ok, prefix}
    end
  end

  defp normalize_prefix(prefix), do: {:error, {:invalid_mcp_prefix, prefix}}

  defp normalize_required(required) when is_boolean(required), do: {:ok, required}
  defp normalize_required(required), do: {:error, {:invalid_mcp_required, required}}

  defp normalize_timeout(nil), do: {:ok, nil}
  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: {:ok, timeout}
  defp normalize_timeout(timeout), do: {:error, {:invalid_mcp_timeout, timeout}}

  defp normalize_idempotency(value) when is_atom(value) do
    if value in Operation.valid_idempotencies() do
      {:ok, value}
    else
      {:error, {:invalid_mcp_idempotency, value}}
    end
  end

  defp normalize_idempotency(value) when is_binary(value) do
    value = String.trim(value)

    Operation.valid_idempotencies()
    |> Enum.find(&(Atom.to_string(&1) == value))
    |> case do
      nil -> {:error, {:invalid_mcp_idempotency, value}}
      value -> {:ok, value}
    end
  end

  defp normalize_idempotency(value), do: {:error, {:invalid_mcp_idempotency, value}}

  defp normalize_metadata(nil), do: {:ok, %{}}
  defp normalize_metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  defp normalize_metadata(metadata), do: {:error, {:invalid_mcp_metadata, metadata}}

  defp normalize_client(client) when is_atom(client), do: {:ok, client}
  defp normalize_client(client), do: {:error, {:invalid_mcp_client, client}}

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

  defp operation_name(%__MODULE__{} = source, remote_name) do
    (source.prefix || default_prefix(source.endpoint)) <> operation_slug(remote_name)
  end

  defp default_prefix(endpoint), do: "mcp_#{operation_slug(metadata_value(endpoint))}_"

  defp operation_slug(name) do
    name
    |> to_string()
    |> Macro.underscore()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "tool"
      slug -> slug
    end
  end

  defp fetch_remote_tool(routes, name) do
    case Map.fetch(routes, to_string(name)) do
      {:ok, remote_name} -> {:ok, remote_name}
      :error -> {:error, {:missing_operation_handler, name}}
    end
  end

  defp client(%__MODULE__{} = source, opts) do
    opts
    |> Keyword.get(:context, %{})
    |> case do
      %{mcp_client: client} when is_atom(client) -> client
      %{"mcp_client" => client} when is_atom(client) -> client
      _context -> source.client
    end
  end

  defp call_opts(%__MODULE__{timeout: nil}), do: []
  defp call_opts(%__MODULE__{timeout: timeout}), do: [timeout: timeout]

  defp metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp metadata_value(value), do: to_string(value)

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
