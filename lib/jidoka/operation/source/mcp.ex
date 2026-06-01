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

  @transport_layers [:stdio, :shell, :sse, :streamable_http]
  @transport_option_keys [
    :command,
    :args,
    :env,
    :cwd,
    :base_url,
    :base_path,
    :sse_path,
    :headers,
    :method,
    :url
  ]

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
          transport: term(),
          client_info: map(),
          protocol_version: String.t() | nil,
          capabilities: map(),
          timeouts: map(),
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
    transport: nil,
    client_info: %{"name" => "jidoka"},
    protocol_version: nil,
    capabilities: %{},
    timeouts: %{},
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
         {:ok, transport} <- normalize_transport(Schema.get_key(attrs, :transport)),
         {:ok, client_info} <-
           normalize_client_info(Schema.get_key(attrs, :client_info, %{"name" => "jidoka"})),
         {:ok, protocol_version} <-
           normalize_protocol_version(Schema.get_key(attrs, :protocol_version)),
         {:ok, capabilities} <-
           normalize_named_map(Schema.get_key(attrs, :capabilities, %{}), :capabilities),
         {:ok, timeouts} <- normalize_named_map(Schema.get_key(attrs, :timeouts, %{}), :timeouts),
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
         transport: transport,
         client_info: client_info,
         protocol_version: protocol_version,
         capabilities: capabilities,
         timeouts: timeouts,
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
          "transport" => metadata_value(source.transport),
          "client_info" => source.client_info,
          "protocol_version" => source.protocol_version,
          "capabilities" => source.capabilities,
          "timeouts" => source.timeouts,
          "remote_tool" => remote_name,
          "prefix" => source.prefix,
          "parameters_schema" => tool.input_schema
        })
        |> reject_nil_values()
    )
  end

  defp tools(%__MODULE__{tools: [_ | _] = tools}, _opts), do: {:ok, tools}

  defp tools(%__MODULE__{} = source, opts) do
    client = client(source, opts)

    result =
      with :ok <- prepare_endpoint(client, source) do
        list_tools(client, source, call_opts(source))
      end

    case result do
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
    with :ok <- prepare_endpoint(client, source) do
      if ensure_client_function?(client, :call_tool, 4) do
        client
        |> apply(:call_tool, [source.endpoint, remote_name, arguments, opts])
        |> normalize_call_tool_response(source, remote_name)
      else
        {:error, {:invalid_mcp_client, client}}
      end
    end
  rescue
    exception -> {:error, exception}
  end

  defp prepare_endpoint(_client, %__MODULE__{transport: nil}), do: :ok

  defp prepare_endpoint(client, %__MODULE__{} = source) do
    with :ok <- ensure_runtime_endpoint(source.endpoint),
         true <- ensure_client_function?(client, :register_endpoint, 1),
         {:ok, endpoint} <- endpoint(source) do
      case apply(client, :register_endpoint, [endpoint]) do
        {:ok, _endpoint} -> :ok
        {:error, {:endpoint_already_registered, _endpoint_id}} -> :ok
        {:error, reason} -> {:error, {:mcp_endpoint_registration_failed, source.endpoint, reason}}
        other -> {:error, {:invalid_mcp_endpoint_registration_response, other}}
      end
    else
      false -> {:error, {:invalid_mcp_client, client}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  defp ensure_runtime_endpoint(endpoint) when is_atom(endpoint) and not is_nil(endpoint), do: :ok

  defp ensure_runtime_endpoint(endpoint),
    do: {:error, {:invalid_mcp_runtime_endpoint, endpoint}}

  defp endpoint(%__MODULE__{} = source) do
    Jido.MCP.Endpoint.new(source.endpoint, %{
      transport: source.transport,
      client_info: source.client_info,
      protocol_version: source.protocol_version,
      capabilities: source.capabilities,
      timeouts: source.timeouts
    })
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

  defp normalize_transport(nil), do: {:ok, nil}

  defp normalize_transport({layer, opts} = transport)
       when layer in @transport_layers and is_list(opts),
       do: {:ok, transport}

  defp normalize_transport(%{} = transport) do
    with {:ok, layer} <-
           normalize_transport_layer(
             Schema.get_key(transport, :type) ||
               Schema.get_key(transport, :layer) ||
               Schema.get_key(transport, :transport)
           ),
         {:ok, opts} <-
           normalize_transport_opts(Map.drop(transport, [:type, "type", :layer, "layer", :transport, "transport"])) do
      {:ok, {layer, opts}}
    end
  end

  defp normalize_transport(transport), do: {:error, {:invalid_mcp_transport, transport}}

  defp normalize_transport_layer(layer) when layer in @transport_layers, do: {:ok, layer}

  defp normalize_transport_layer(layer) when is_binary(layer) do
    layer = layer |> String.trim() |> String.downcase()

    @transport_layers
    |> Enum.find(&(Atom.to_string(&1) == layer))
    |> case do
      nil -> {:error, {:invalid_mcp_transport_layer, layer}}
      layer -> {:ok, layer}
    end
  end

  defp normalize_transport_layer(layer), do: {:error, {:invalid_mcp_transport_layer, layer}}

  defp normalize_transport_opts(opts) when is_map(opts) do
    opts
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      case normalize_transport_option_key(key) do
        {:ok, key} -> {:cont, {:ok, [{key, value} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, opts} -> {:ok, Enum.reverse(opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_transport_option_key(key) when key in @transport_option_keys, do: {:ok, key}

  defp normalize_transport_option_key(key) when is_binary(key) do
    @transport_option_keys
    |> Enum.find(&(Atom.to_string(&1) == key))
    |> case do
      nil -> {:error, {:invalid_mcp_transport_option, key}}
      key -> {:ok, key}
    end
  end

  defp normalize_transport_option_key(key), do: {:error, {:invalid_mcp_transport_option, key}}

  defp normalize_client_info(nil), do: {:ok, %{"name" => "jidoka"}}

  defp normalize_client_info(%{} = client_info) do
    case Map.get(client_info, :name, Map.get(client_info, "name")) do
      name when is_binary(name) and name != "" -> {:ok, stringify_keys(client_info)}
      _other -> {:error, {:invalid_mcp_client_info, client_info}}
    end
  end

  defp normalize_client_info(client_info), do: {:error, {:invalid_mcp_client_info, client_info}}

  defp normalize_protocol_version(nil), do: {:ok, nil}

  defp normalize_protocol_version(protocol_version)
       when is_binary(protocol_version) and protocol_version != "",
       do: {:ok, protocol_version}

  defp normalize_protocol_version(protocol_version),
    do: {:error, {:invalid_mcp_protocol_version, protocol_version}}

  defp normalize_named_map(nil, _field), do: {:ok, %{}}
  defp normalize_named_map(%{} = map, _field), do: {:ok, stringify_keys(map)}
  defp normalize_named_map(value, field), do: {:error, {:invalid_mcp_map, field, value}}

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

  defp call_opts(%__MODULE__{} = source) do
    []
    |> maybe_put_timeout(source.timeout)
    |> maybe_put_timeouts(source.timeouts)
  end

  defp maybe_put_timeout(opts, nil), do: opts
  defp maybe_put_timeout(opts, timeout), do: Keyword.put(opts, :timeout, timeout)

  defp maybe_put_timeouts(opts, timeouts) when timeouts in [nil, %{}], do: opts
  defp maybe_put_timeouts(opts, timeouts), do: Keyword.put(opts, :timeouts, timeouts)

  defp metadata_value(nil), do: nil
  defp metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp metadata_value(value) when is_tuple(value), do: inspect(value)
  defp metadata_value(value), do: to_string(value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
