defmodule Jidoka.Import.Tools do
  @moduledoc false

  alias Jidoka.Agent.Spec
  alias Jidoka.Import.Normalize
  alias Jidoka.Import.Registry
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Catalog, as: CatalogSource
  alias Jidoka.Operation.Source.MCP, as: MCPSource
  alias Jidoka.Runtime.JidoActions
  alias Jidoka.Schema

  @unsupported_tool_sources []

  @type data :: %{
          required(:operations) => [Spec.Operation.t()],
          required(:sources) => [map()]
        }

  @spec expand(map(), keyword()) :: {:ok, data()} | {:error, term()}
  def expand(tools, opts) when is_map(tools) do
    with :ok <- reject_unsupported_tool_sources(tools),
         {:ok, actions} <- action_operations(tools, opts),
         {:ok, ash_resources, ash_sources} <- ash_resource_operations(tools, opts),
         {:ok, browsers, browser_sources} <- browser_operations(tools),
         {:ok, mcps, mcp_sources} <- mcp_operations(tools),
         {:ok, catalogs, catalog_sources} <- catalog_operations(tools, opts) do
      {:ok,
       %{
         operations: actions ++ ash_resources ++ browsers ++ mcps ++ catalogs,
         sources: ash_sources ++ browser_sources ++ mcp_sources ++ catalog_sources
       }}
    end
  end

  defp reject_unsupported_tool_sources(tools) when is_map(tools) do
    Enum.find_value(@unsupported_tool_sources, :ok, fn key ->
      case Schema.fetch_key(tools, key) do
        {:ok, _value} -> {:error, {:unsupported_tool_source, key}}
        :error -> false
      end
    end)
  end

  defp action_operations(tools, opts) when is_map(tools) do
    tools
    |> Normalize.tool_entries(:actions, :action)
    |> Enum.reduce_while({:ok, []}, fn action_ref, {:ok, operations} ->
      with {:ok, action} <- resolve_action(action_ref, opts),
           {:ok, operation} <- operation_from_action(action) do
        {:cont, {:ok, [operation | operations]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> Normalize.reverse_result()
  end

  defp ash_resource_operations(tools, opts) when is_map(tools) do
    tools
    |> Normalize.tool_entries(:ash_resources, :ash_resource)
    |> Enum.reduce_while({:ok, [], []}, fn resource_ref, {:ok, operations, sources} ->
      with {:ok, resource_data} <- normalize_ash_resource_ref(resource_ref, opts),
           {:ok, resource_operations, source_metadata} <-
             ash_resource_operations_from_ref(resource_data) do
        {:cont, {:ok, operations ++ resource_operations, sources ++ [source_metadata]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp browser_operations(tools) when is_map(tools) do
    tools
    |> Normalize.tool_entries(:browsers, :browser)
    |> Enum.reduce_while({:ok, [], []}, fn browser_ref, {:ok, operations, sources} ->
      with {:ok, browser} <- normalize_browser_ref(browser_ref),
           {:ok, browser_operations} <- browser_operations_from_ref(browser) do
        source = %{
          "source" => "browser",
          "name" => browser.name,
          "mode" => Atom.to_string(browser.mode),
          "allow" => browser.allow
        }

        {:cont, {:ok, operations ++ browser_operations, sources ++ [source]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp mcp_operations(tools) when is_map(tools) do
    tools
    |> Normalize.tool_entries(:mcp_tools, :mcp_tool)
    |> Enum.reduce_while({:ok, [], []}, fn mcp_ref, {:ok, acc_operations, sources} ->
      with {:ok, source} <- normalize_mcp_ref(mcp_ref),
           {:ok, source_operations} <- Source.operations(source) do
        source_metadata = %{
          "source" => "mcp",
          "endpoint" => Normalize.metadata_value(source.endpoint),
          "prefix" => source.prefix,
          "required" => source.required,
          "transport" => Normalize.metadata_value(source.transport),
          "client_info" => source.client_info,
          "protocol_version" => source.protocol_version,
          "capabilities" => source.capabilities,
          "timeouts" => source.timeouts,
          "tools" => Enum.map(source.tools, & &1.name)
        }

        {:cont, {:ok, acc_operations ++ source_operations, sources ++ [Normalize.reject_nil_values(source_metadata)]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp catalog_operations(tools, opts) when is_map(tools) do
    tools
    |> Normalize.tool_entries(:catalogs, :catalog)
    |> Enum.reduce_while({:ok, [], []}, fn catalog_ref, {:ok, acc_operations, sources} ->
      with {:ok, source} <- normalize_catalog_ref(catalog_ref, opts),
           {:ok, source_operations} <- Source.operations(source) do
        source_metadata = %{
          "source" => "catalog",
          "catalog" => inspect(source.catalog),
          "catalog_id" => source.catalog_value.id,
          "prefix" => source.prefix,
          "timeout" => source.timeout,
          "max_calls" => source.max_calls,
          "max_parallel_calls" => source.max_parallel_calls,
          "require_read_only?" => source.require_read_only?,
          "result" => Atom.to_string(source.result),
          "tools" => Enum.map(Jido.Action.Catalog.list(source.catalog_value), & &1.id)
        }

        {:cont, {:ok, acc_operations ++ source_operations, sources ++ [Normalize.reject_nil_values(source_metadata)]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_action(%{} = action_ref, opts) do
    case Schema.get_key(action_ref, :ref) || Schema.get_key(action_ref, :action) do
      nil -> {:error, {:invalid_action_ref, action_ref}}
      ref -> resolve_action(ref, opts)
    end
  end

  defp resolve_action(action, _opts) when is_atom(action) and not is_nil(action) do
    if action_module?(action) do
      {:ok, action}
    else
      {:error, {:invalid_action_module, action}}
    end
  end

  defp resolve_action(ref, opts) when is_binary(ref), do: Registry.fetch(:actions, ref, opts)
  defp resolve_action(other, _opts), do: {:error, {:invalid_action_ref, other}}

  defp action_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :to_tool, 0)
  end

  defp operation_from_action(action) do
    {:ok, JidoActions.operation_from_action!(action)}
  rescue
    exception -> {:error, {:invalid_action_module, action, exception}}
  end

  defp ash_resource_operations_from_ref(%{} = resource_data) do
    actions = ash_jido_actions(resource_data.resource, resource_data.actions)

    operations =
      actions
      |> Enum.map(&JidoActions.operation_from_action!/1)
      |> Enum.map(&tag_ash_operation(&1, resource_data))

    source = %{
      "source" => "ash_resource",
      "resource" => inspect(resource_data.resource),
      "actions" => resource_data.actions,
      "expanded?" => actions != []
    }

    {:ok, operations, source}
  rescue
    exception -> {:error, {:invalid_ash_resource, resource_data, exception}}
  end

  defp browser_operations_from_ref(%{} = browser) do
    operations =
      browser.mode
      |> Jidoka.Browser.tool_modules()
      |> Enum.map(&JidoActions.operation_from_action!/1)
      |> Enum.map(&tag_browser_operation(&1, browser))

    {:ok, operations}
  rescue
    exception -> {:error, {:invalid_browser_source, browser, exception}}
  end

  defp tag_ash_operation(%Spec.Operation{} = operation, resource_data) do
    %Spec.Operation{
      operation
      | description: resource_data.description || operation.description,
        idempotency: resource_data.idempotency,
        metadata:
          operation.metadata
          |> Map.merge(resource_data.metadata)
          |> Map.merge(%{
            "source" => "ash_resource",
            "kind" => "ash_resource",
            "resource" => inspect(resource_data.resource),
            "action" => operation.name
          })
    }
  end

  defp tag_browser_operation(%Spec.Operation{} = operation, browser) do
    %Spec.Operation{
      operation
      | description: browser.description || operation.description,
        idempotency: browser.idempotency,
        metadata:
          operation.metadata
          |> Map.merge(browser.metadata)
          |> Map.merge(%{
            "source" => "browser",
            "kind" => "browser",
            "browser" => browser.name,
            "mode" => Atom.to_string(browser.mode),
            "allow" => browser.allow
          })
    }
  end

  defp ash_jido_actions(resource, requested_actions) do
    with module <- ash_jido_tools_module(),
         {:module, module} <- Code.ensure_compiled(module),
         actions when is_list(actions) <- apply(module, :actions, [resource]) do
      maybe_filter_ash_jido_actions(actions, requested_actions)
    else
      _reason -> []
    end
  rescue
    _exception -> []
  end

  defp ash_jido_tools_module do
    Application.get_env(:jidoka, :ash_jido_tools, AshJido.Tools)
  end

  defp maybe_filter_ash_jido_actions(actions, requested_actions)
       when requested_actions in [nil, []],
       do: actions

  defp maybe_filter_ash_jido_actions(actions, requested_actions) do
    requested = MapSet.new(requested_actions)

    Enum.filter(actions, fn action ->
      action_tool_name(action) in requested or action_module_name(action) in requested
    end)
  end

  defp action_tool_name(action) do
    case action.to_tool() do
      %{name: name} -> to_string(name)
      _tool -> nil
    end
  rescue
    _exception -> nil
  end

  defp action_module_name(action) do
    action
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp normalize_ash_resource_ref(%{} = attrs, opts) do
    attrs = Normalize.stringify_keys(attrs)

    with {:ok, resource} <-
           resolve_ash_resource(
             Schema.get_key(attrs, :resource) || Schema.get_key(attrs, :ref),
             opts
           ),
         {:ok, actions} <-
           Normalize.name_list(Schema.get_key(attrs, :actions, []), :ash_resource_actions),
         {:ok, idempotency} <-
           Normalize.idempotency(Schema.get_key(attrs, :idempotency, :idempotent)),
         {:ok, metadata} <- Normalize.metadata(Schema.get_key(attrs, :metadata, %{})) do
      {:ok,
       %{
         resource: resource,
         actions: actions,
         description: Schema.get_key(attrs, :description),
         idempotency: idempotency,
         metadata: metadata
       }}
    end
  end

  defp normalize_ash_resource_ref(ref, opts), do: normalize_ash_resource_ref(%{"resource" => ref}, opts)

  defp resolve_ash_resource(nil, _opts), do: {:error, :missing_ash_resource_ref}

  defp resolve_ash_resource(resource, _opts) when is_atom(resource) and not is_nil(resource),
    do: {:ok, resource}

  defp resolve_ash_resource(ref, opts) when is_binary(ref), do: Registry.fetch(:ash_resources, ref, opts)
  defp resolve_ash_resource(other, _opts), do: {:error, {:invalid_ash_resource_ref, other}}

  defp normalize_browser_ref(%{} = attrs) do
    attrs = Normalize.stringify_keys(attrs)

    with {:ok, name} <-
           Normalize.name(Schema.get_key(attrs, :name) || Schema.get_key(attrs, :ref)),
         {:ok, mode} <- Jidoka.Browser.normalize_mode(Schema.get_key(attrs, :mode, :read_only)),
         {:ok, allow} <- Normalize.string_list(Schema.get_key(attrs, :allow, []), :browser_allow),
         {:ok, idempotency} <-
           Normalize.idempotency(Schema.get_key(attrs, :idempotency, :idempotent)),
         {:ok, metadata} <- Normalize.metadata(Schema.get_key(attrs, :metadata, %{})) do
      {:ok,
       %{
         name: name,
         mode: mode,
         allow: allow,
         description: Schema.get_key(attrs, :description),
         idempotency: idempotency,
         metadata: metadata
       }}
    end
  end

  defp normalize_browser_ref(name), do: normalize_browser_ref(%{"name" => name})

  defp normalize_mcp_ref(%{} = attrs) do
    attrs = Normalize.stringify_keys(attrs)

    MCPSource.new(
      endpoint: Schema.get_key(attrs, :endpoint) || Schema.get_key(attrs, :ref),
      prefix: Schema.get_key(attrs, :prefix),
      tools: Schema.get_key(attrs, :tools, []),
      required: Schema.get_key(attrs, :required, false),
      transport: Schema.get_key(attrs, :transport),
      client_info: Schema.get_key(attrs, :client_info, %{"name" => "jidoka"}),
      protocol_version: Schema.get_key(attrs, :protocol_version),
      capabilities: Schema.get_key(attrs, :capabilities, %{}),
      timeouts: Schema.get_key(attrs, :timeouts, %{}),
      timeout: Schema.get_key(attrs, :timeout),
      description: Schema.get_key(attrs, :description),
      idempotency: Schema.get_key(attrs, :idempotency, :idempotent),
      metadata: Schema.get_key(attrs, :metadata, %{})
    )
  end

  defp normalize_mcp_ref(endpoint), do: normalize_mcp_ref(%{"endpoint" => endpoint})

  defp normalize_catalog_ref(%{} = attrs, opts) do
    attrs = Normalize.stringify_keys(attrs)

    with {:ok, catalog} <-
           resolve_catalog(
             Schema.get_key(attrs, :catalog) || Schema.get_key(attrs, :module) || Schema.get_key(attrs, :ref),
             opts
           ) do
      CatalogSource.new(
        catalog: catalog,
        prefix: Schema.get_key(attrs, :prefix, "catalog_"),
        description: Schema.get_key(attrs, :description),
        timeout: Schema.get_key(attrs, :timeout, 1_500),
        max_calls: Schema.get_key(attrs, :max_calls, 12),
        max_parallel_calls: Schema.get_key(attrs, :max_parallel_calls, 8),
        require_read_only?: Schema.get_key(attrs, :require_read_only?, true),
        result: Schema.get_key(attrs, :result, :structured),
        idempotency: Schema.get_key(attrs, :idempotency, :idempotent),
        metadata: Schema.get_key(attrs, :metadata, %{})
      )
    end
  end

  defp normalize_catalog_ref(ref, opts), do: normalize_catalog_ref(%{"catalog" => ref}, opts)

  defp resolve_catalog(nil, _opts), do: {:error, :missing_catalog_ref}

  defp resolve_catalog(catalog, _opts) when is_atom(catalog) and not is_nil(catalog),
    do: {:ok, catalog}

  defp resolve_catalog(ref, opts) when is_binary(ref), do: Registry.fetch(:catalogs, ref, opts)
  defp resolve_catalog(other, _opts), do: {:error, {:invalid_catalog_ref, other}}
end
