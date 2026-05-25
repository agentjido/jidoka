defmodule Jidoka.MCP do
  @moduledoc """
  Jidoka-facing MCP endpoint and tool-sync helpers.

  Jidoka treats MCP servers as a first-class tool source for agents. MCP endpoints
  may come from `:jido_mcp` application config, `jido_mcp` runtime endpoint
  registration, or inline `mcp_tools` DSL entries on compiled agents.
  """

  alias Jido.MCP.{ClientPool, Endpoint}

  @state_key :__jidoka_mcp__

  @type endpoint_ref :: atom() | String.t()
  @type endpoint_config :: %{
          required(:endpoint) => endpoint_ref(),
          required(:prefix) => String.t() | nil,
          optional(:registration) => Endpoint.t()
        }
  @type config :: [endpoint_config()]

  @doc """
  Builds a validated MCP endpoint definition.
  """
  @spec endpoint(atom(), map() | keyword()) :: {:ok, Endpoint.t()} | {:error, term()}
  def endpoint(id, attrs) do
    Endpoint.new(id, attrs)
    |> normalize_mcp_result(operation: :endpoint, endpoint: id, field: :endpoint, value: attrs)
  end

  @doc """
  Registers a runtime MCP endpoint with `jido_mcp`.

  This mirrors `Jido.MCP.register_endpoint/1` and intentionally surfaces
  duplicate endpoint ids as errors.
  """
  @spec register_endpoint(atom(), map() | keyword()) :: {:ok, Endpoint.t()} | {:error, term()}
  def register_endpoint(id, attrs) do
    with {:ok, endpoint} <- endpoint(id, attrs) do
      Jido.MCP.register_endpoint(endpoint)
    end
    |> normalize_mcp_result(operation: :register_endpoint, endpoint: id, field: :endpoint, value: attrs)
  end

  @doc """
  Ensures a runtime MCP endpoint exists.

  Unlike `register_endpoint/2`, this is idempotent for matching endpoint
  definitions and returns an explicit conflict error for mismatched definitions.
  Jidoka uses this for inline `mcp_tools` endpoint declarations.
  """
  @spec ensure_endpoint(atom(), map() | keyword()) :: {:ok, Endpoint.t()} | {:error, term()}
  def ensure_endpoint(id, attrs) do
    with {:ok, endpoint} <- endpoint(id, attrs) do
      ensure_endpoint(endpoint)
    end
    |> normalize_mcp_result(operation: :ensure_endpoint, endpoint: id, field: :endpoint, value: attrs)
  end

  @doc """
  Returns the currently known `jido_mcp` endpoint ids.
  """
  @spec endpoint_ids() :: [atom()]
  def endpoint_ids, do: ClientPool.endpoint_ids()

  @doc """
  Returns runtime status for a configured or registered endpoint.
  """
  @spec endpoint_status(endpoint_ref()) :: {:ok, map()} | {:error, term()}
  def endpoint_status(endpoint) do
    with {:ok, endpoint_id} <- ClientPool.resolve_endpoint_id(endpoint) do
      Jido.MCP.endpoint_status(endpoint_id)
    end
    |> normalize_mcp_result(operation: :endpoint_status, endpoint: endpoint, field: :endpoint, value: endpoint)
  end

  @doc """
  Syncs an MCP endpoint's tools into a running Jidoka/Jido.AI agent.

  Options:

  - `:endpoint` - configured or registered endpoint id
  - `:prefix` - optional tool-name prefix
  - `:transport` - optional runtime endpoint transport definition
  - `:client_info` - optional runtime endpoint client metadata
  - `:replace_existing` - whether to remove previous proxies first, default `true`
  """
  @spec sync_tools(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_tools(agent_server, opts) when is_list(opts) do
    with {:ok, entry} <- normalize_entry(Enum.into(opts, %{})),
         :ok <- ensure_registered_endpoint(entry) do
      params =
        %{
          endpoint_id: entry.endpoint,
          agent_server: agent_server,
          replace_existing: Keyword.get(opts, :replace_existing, true)
        }
        |> maybe_put_prefix(entry.prefix)

      sync_module().run(params, %{})
    end
    |> normalize_mcp_result(operation: :sync_tools, target: agent_server, value: opts)
  end

  @doc false
  @spec normalize_dsl([struct()]) :: {:ok, config()} | {:error, String.t()}
  def normalize_dsl(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      with {:ok, normalized} <- normalize_dsl_entry(entry),
           :ok <- ensure_unique_endpoint(normalized, acc) do
        {:cont, {:ok, acc ++ [normalized]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  @spec normalize_imported([map()]) :: {:ok, config()} | {:error, String.t()}
  def normalize_imported(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      with true <- is_map(entry) or {:error, "mcp_tools entries must be maps"},
           {:ok, normalized} <- normalize_entry(entry),
           :ok <- ensure_unique_endpoint(normalized, acc) do
        {:cont, {:ok, acc ++ [normalized]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize_imported(other),
    do: {:error, "mcp_tools must be a list of maps, got: #{inspect(other)}"}

  @doc false
  @spec validate_dsl_entry(struct()) :: :ok | {:error, String.t()}
  def validate_dsl_entry(%Jidoka.Agent.Dsl.MCPTools{} = entry) do
    with {:ok, _normalized} <- normalize_dsl_entry(entry) do
      :ok
    end
  end

  @doc false
  @spec on_before_cmd(Jido.Agent.t(), term(), config()) :: {:ok, Jido.Agent.t(), term()}
  def on_before_cmd(agent, action, []), do: {:ok, agent, action}

  def on_before_cmd(agent, {:ai_react_start, _params} = action, config) when is_list(config) do
    context =
      case action do
        {:ai_react_start, %{tool_context: tool_context}} when is_map(tool_context) -> tool_context
        _ -> %{}
      end

    synced = agent.state |> Map.get(@state_key, %{}) |> Map.get(:synced, %{})

    {agent, synced, errors} =
      Enum.reduce(config, {agent, synced, []}, fn entry, {agent_acc, synced_acc, errors_acc} ->
        key = sync_key(entry)

        if Map.get(synced_acc, key, false) do
          trace_mcp(context, entry, :skip)
          {agent_acc, synced_acc, errors_acc}
        else
          case sync_endpoint(entry, agent_acc) do
            {:ok, updated_agent} ->
              trace_mcp(context, entry, :sync)
              {updated_agent, Map.put(synced_acc, key, true), errors_acc}

            {:error, reason} ->
              trace_mcp(context, entry, :error, %{error: Jidoka.Error.format(reason)})
              {agent_acc, synced_acc, [format_error(entry, reason) | errors_acc]}
          end
        end
      end)

    :ok =
      Jidoka.Debug.record_runtime_meta(
        context,
        %{
          mcp_tools: Enum.map(config, &format_entry/1),
          mcp_errors: Enum.reverse(errors)
        }
        |> drop_empty_errors()
      )

    {:ok, put_mcp_state(agent, synced, errors), action}
  end

  def on_before_cmd(agent, action, _config), do: {:ok, agent, action}

  defp normalize_dsl_entry(%Jidoka.Agent.Dsl.MCPTools{} = entry) do
    normalize_entry(%{
      endpoint: entry.endpoint,
      prefix: entry.prefix,
      transport: entry.transport,
      client_info: entry.client_info,
      protocol_version: entry.protocol_version,
      capabilities: entry.capabilities,
      timeouts: entry.timeouts
    })
  end

  defp normalize_entry(entry) when is_map(entry) do
    endpoint = Map.get(entry, :endpoint, Map.get(entry, "endpoint"))
    prefix = Map.get(entry, :prefix, Map.get(entry, "prefix"))

    with {:ok, normalized_endpoint} <- normalize_endpoint(endpoint),
         {:ok, normalized_prefix} <- normalize_prefix(prefix),
         {:ok, registration} <- normalize_registration(normalized_endpoint, entry) do
      entry = %{endpoint: normalized_endpoint, prefix: normalized_prefix}

      {:ok, maybe_put_registration(entry, registration)}
    end
  end

  defp normalize_endpoint(endpoint) when is_atom(endpoint), do: {:ok, endpoint}

  defp normalize_endpoint(endpoint) when is_binary(endpoint) do
    trimmed = String.trim(endpoint)

    if trimmed == "" do
      {:error, "mcp endpoint must not be empty"}
    else
      {:ok, trimmed}
    end
  end

  defp normalize_endpoint(other),
    do: {:error, "mcp endpoint must be an atom or string, got: #{inspect(other)}"}

  defp normalize_prefix(nil), do: {:ok, nil}

  defp normalize_prefix(prefix) when is_binary(prefix) do
    trimmed = String.trim(prefix)

    if trimmed == "" do
      {:error, "mcp prefix must not be empty when provided"}
    else
      {:ok, trimmed}
    end
  end

  defp normalize_prefix(other),
    do: {:error, "mcp prefix must be a string when provided, got: #{inspect(other)}"}

  defp normalize_registration(endpoint, entry) do
    transport = Map.get(entry, :transport, Map.get(entry, "transport"))

    if is_nil(transport) do
      {:ok, nil}
    else
      with :ok <- ensure_runtime_endpoint_id(endpoint),
           attrs <- endpoint_attrs(entry),
           {:ok, endpoint} <- Endpoint.new(endpoint, attrs) do
        {:ok, endpoint}
      else
        {:error, reason} -> {:error, format_endpoint_error(reason)}
      end
    end
  end

  defp ensure_runtime_endpoint_id(endpoint) when is_atom(endpoint), do: :ok

  defp ensure_runtime_endpoint_id(endpoint) do
    {:error, "inline MCP endpoint definitions require an atom endpoint id, got: #{inspect(endpoint)}"}
  end

  defp endpoint_attrs(entry) do
    %{
      transport: Map.get(entry, :transport, Map.get(entry, "transport")),
      client_info: Map.get(entry, :client_info, Map.get(entry, "client_info", %{name: "jidoka"})),
      protocol_version: Map.get(entry, :protocol_version, Map.get(entry, "protocol_version")),
      capabilities: Map.get(entry, :capabilities, Map.get(entry, "capabilities", %{})),
      timeouts: Map.get(entry, :timeouts, Map.get(entry, "timeouts", %{}))
    }
  end

  defp maybe_put_registration(entry, nil), do: entry
  defp maybe_put_registration(entry, %Endpoint{} = endpoint), do: Map.put(entry, :registration, endpoint)

  defp format_endpoint_error(reason) when is_binary(reason), do: reason
  defp format_endpoint_error(reason), do: "invalid MCP endpoint definition: #{inspect(reason)}"

  defp ensure_unique_endpoint(entry, acc) do
    if Enum.any?(acc, fn existing -> existing.endpoint == entry.endpoint end) do
      {:error, "mcp endpoint #{inspect(entry.endpoint)} is defined more than once"}
    else
      :ok
    end
  end

  defp put_mcp_state(agent, synced, errors) do
    state =
      agent.state
      |> Map.get(@state_key, %{})
      |> Map.put(:synced, synced)
      |> Map.put(:last_errors, Enum.reverse(errors))

    %{agent | state: Map.put(agent.state, @state_key, state)}
  end

  defp sync_endpoint(entry, agent) do
    params =
      %{
        endpoint_id: entry.endpoint,
        agent_server: self(),
        agent: agent,
        replace_existing: false
      }
      |> maybe_put_prefix(entry.prefix)

    with :ok <- ensure_registered_endpoint(entry) do
      sync_module().run(params, %{})
    end
    |> case do
      {:ok, %{agent: %Jido.Agent{} = updated_agent}} -> {:ok, updated_agent}
      {:ok, _result} -> {:ok, agent}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp maybe_put_prefix(params, nil), do: params
  defp maybe_put_prefix(params, prefix), do: Map.put(params, :prefix, prefix)

  defp sync_module do
    Application.get_env(:jidoka, :mcp_sync_module, Jidoka.MCP.Sync)
  end

  defp ensure_registered_endpoint(%{registration: %Endpoint{} = endpoint}) do
    ensure_endpoint(endpoint)
    |> case do
      {:ok, _endpoint} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_registered_endpoint(_entry), do: :ok

  defp ensure_endpoint(%Endpoint{} = endpoint) do
    case Jido.MCP.register_endpoint(endpoint) do
      {:ok, endpoint} ->
        {:ok, endpoint}

      {:error, {:endpoint_already_registered, endpoint_id}} ->
        case ClientPool.fetch_endpoint(endpoint_id) do
          {:ok, ^endpoint} -> {:ok, endpoint}
          {:ok, existing} -> {:error, {:endpoint_conflict, endpoint_id, existing, endpoint}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_key(%{endpoint: endpoint, prefix: prefix}), do: {endpoint, prefix}

  defp format_entry(%{endpoint: endpoint, prefix: nil}), do: to_string(endpoint)
  defp format_entry(%{endpoint: endpoint, prefix: prefix}), do: "#{endpoint}:#{prefix}"

  defp format_error(entry, reason) do
    error =
      Jidoka.Error.Normalize.mcp_error(reason,
        operation: :sync_tools,
        endpoint: entry.endpoint,
        target: entry.endpoint,
        value: entry
      )

    %{
      endpoint: entry.endpoint,
      prefix: entry.prefix,
      reason: error,
      message: Jidoka.Error.format(error)
    }
  end

  defp normalize_mcp_result({:ok, _value} = ok, _context), do: ok

  defp normalize_mcp_result({:error, reason}, context) do
    {:error, Jidoka.Error.Normalize.mcp_error(reason, context)}
  end

  defp normalize_mcp_result(other, context) do
    {:error, Jidoka.Error.Normalize.mcp_error({:invalid_result, other}, context)}
  end

  defp drop_empty_errors(%{mcp_errors: []} = meta), do: Map.delete(meta, :mcp_errors)
  defp drop_empty_errors(meta), do: meta

  defp trace_mcp(context, entry, event, metadata \\ %{}) do
    Jidoka.Trace.emit(
      :mcp,
      Jidoka.Trace.correlation_refs(context)
      |> Map.merge(%{
        event: event,
        endpoint: entry.endpoint,
        prefix: entry.prefix,
        request_id: Map.get(context, Jidoka.Subagent.request_id_key()),
        agent_id: Map.get(context, Jidoka.Trace.agent_id_key())
      })
      |> Map.merge(metadata)
    )
  end
end
