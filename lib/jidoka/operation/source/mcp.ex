defmodule Jidoka.Operation.Source.MCP do
  @moduledoc """
  Operation source backed by `jido_mcp`.

  MCP tools are normalized into ordinary Jidoka operations. At runtime the
  operation source routes the local operation name back to the remote MCP tool
  name and calls the configured endpoint through `Jido.MCP`.
  """

  @behaviour Jidoka.Operation.Source

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Context
  alias Jidoka.Effect
  alias Jidoka.Operation.Source.MCP.Tools
  alias Jidoka.Operation.Source.MCP.Transport
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

  @schema Zoi.struct(
            __MODULE__,
            %{
              endpoint: Zoi.any() |> Zoi.nullish(),
              prefix: Zoi.string() |> Zoi.nullish(),
              tools: Zoi.array(Zoi.map()) |> Zoi.default([]),
              required: Zoi.boolean() |> Zoi.default(false),
              transport: Zoi.any() |> Zoi.nullish(),
              client_info: Zoi.map() |> Zoi.default(%{"name" => "jidoka"}),
              protocol_version: Zoi.string() |> Zoi.nullish(),
              capabilities: Zoi.map() |> Zoi.default(%{}),
              timeouts: Zoi.map() |> Zoi.default(%{}),
              timeout: Zoi.integer() |> Zoi.nullish(),
              description: Zoi.string() |> Zoi.nullish(),
              idempotency: Schema.atom_enum(Operation.valid_idempotencies()) |> Zoi.default(:idempotent),
              metadata: Zoi.map() |> Zoi.default(%{}),
              client: Zoi.atom() |> Zoi.default(Jido.MCP)
            },
            coerce: true
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, endpoint} <- normalize_endpoint(Schema.get_key(attrs, :endpoint)),
         {:ok, prefix} <- normalize_prefix(Schema.get_key(attrs, :prefix)),
         {:ok, tools} <- Tools.normalize_static(Schema.get_key(attrs, :tools, [])),
         {:ok, required} <- normalize_required(Schema.get_key(attrs, :required, false)),
         {:ok, transport} <- Transport.normalize(Schema.get_key(attrs, :transport)),
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

      {:ok,
       fn
         %Effect.Intent{kind: :operation, payload: payload}, %Effect.Journal{}, %Context{} = context ->
           with {:ok, request} <- Effect.OperationRequest.from_input(payload),
                {:ok, remote_name} <- fetch_remote_tool(routes, request.name) do
             call_tool(client(source, context), source, remote_name, request.arguments, Transport.call_opts(source))
           end

         %Effect.Intent{kind: kind}, _journal, %Context{} ->
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
    if discover_tools?(opts) do
      discover_tools(source, opts)
    else
      discovery_disabled(source)
    end
  end

  defp discover_tools(%__MODULE__{} = source, opts) do
    client = client(source, opts)

    result =
      with :ok <- prepare_endpoint(client, source) do
        list_tools(client, source, Transport.call_opts(source))
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

  defp discover_tools?(opts) when is_list(opts) do
    Keyword.get(opts, :discover_mcp?, false) == true or
      Application.get_env(:jidoka, :mcp_discovery_enabled, false) == true
  end

  defp discover_tools?(_opts), do: Application.get_env(:jidoka, :mcp_discovery_enabled, false) == true

  defp discovery_disabled(%__MODULE__{} = source) do
    if source.required do
      {:error, {:mcp_tool_discovery_disabled, source.endpoint}}
    else
      {:ok, []}
    end
  end

  defp list_tools(client, %__MODULE__{} = source, opts) do
    if ensure_client_function?(client, :list_tools, 2) do
      client
      |> apply(:list_tools, [source.endpoint, opts])
      |> Tools.normalize_list_tools_response()
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
         {:ok, endpoint} <- Transport.endpoint(source) do
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

  defp ensure_client_function?(client, function, arity) when is_atom(client) do
    Code.ensure_loaded?(client) and function_exported?(client, function, arity)
  end

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
    case runtime_context(opts) do
      %{mcp_client: client} when is_atom(client) -> client
      %{"mcp_client" => client} when is_atom(client) -> client
      _context -> source.client
    end
  end

  defp runtime_context(%Context{} = context), do: Context.runtime(context)

  defp runtime_context(opts) when is_list(opts) do
    Keyword.get(opts, :context, %{})
  end

  defp runtime_context(context) when is_map(context), do: context
  defp runtime_context(_context), do: %{}

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
