defmodule Jidoka.Import do
  @moduledoc """
  JSON/YAML import runtime for data-authored Jidoka agents.

  Imports compile into the same `Jidoka.Agent.Spec` contract as the Spark DSL.
  JSON/YAML cannot safely encode executable Elixir values, so action modules and
  context schemas are resolved through caller-provided registries.
  """

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Error
  alias Jidoka.Import.AgentDocument
  alias Jidoka.Import.Registry
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Catalog, as: CatalogSource
  alias Jidoka.Operation.Source.MCP, as: MCPSource
  alias Jidoka.Runtime.JidoActions
  alias Jidoka.Schema

  @type format :: :json | :yaml
  @type registry :: keyword() | map()
  @type option ::
          {:format, format()}
          | {:registries, registry()}
          | {:actions, registry()}
          | {:action_registry, registry()}
          | {:ash_resources, registry()}
          | {:ash_resource_registry, registry()}
          | {:controls, registry()}
          | {:control_registry, registry()}
          | {:catalogs, registry()}
          | {:catalog_registry, registry()}
          | {:context_schemas, registry()}
          | {:context_schema_registry, registry()}
          | {:result_schemas, registry()}
          | {:result_schema_registry, registry()}

  @agent_keys ~w(id model generation instructions context context_schema result result_schema memory runtime_defaults metadata)
  @document_keys ~w(version agent tools controls operations runtime_defaults metadata)
  @unsupported_tool_sources []

  @doc """
  Imports a JSON or YAML agent document string.

  Pass `format: :json` or `format: :yaml` to force a parser. Without a format,
  strings beginning with `{` or `[` are treated as JSON; all others are treated
  as YAML.
  """
  @spec import(String.t(), [option()]) :: {:ok, Spec.t()} | {:error, term()}
  def import(contents, opts \\ []) when is_binary(contents) and is_list(opts) do
    with {:ok, format} <- string_format(contents, opts),
         {:ok, decoded} <- decode_string(contents, format) do
      opts =
        Keyword.put(opts, :source, %{
          "kind" => "string",
          "format" => Atom.to_string(format)
        })

      load(decoded, opts)
    else
      {:error, %_{} = error} -> {:error, error}
      {:error, reason} -> {:error, import_error(reason, field: :format)}
    end
  end

  @doc """
  Compiles decoded import data into `Jidoka.Agent.Spec`.
  """
  @spec load(map(), [option()]) :: {:ok, Spec.t()} | {:error, term()}
  def load(attrs, opts \\ [])

  def load(%{} = attrs, opts) when is_list(opts) do
    with {:ok, document} <- attrs |> normalize_document() |> AgentDocument.new(),
         {:ok, spec_attrs} <- spec_attrs(document, opts),
         {:ok, spec} <- Spec.new(spec_attrs),
         :ok <- validate_operation_names(spec.operations) do
      {:ok, spec}
    else
      {:error, %_{} = error} -> {:error, error}
      {:error, reason} -> {:error, import_error(reason)}
    end
  end

  def load(_attrs, _opts) do
    {:error, import_error(:invalid_document, field: :document)}
  end

  @doc """
  Imports a JSON or YAML agent document string and raises on failure.
  """
  @spec import!(String.t(), [option()]) :: Spec.t()
  def import!(contents, opts \\ []), do: raise_on_error(__MODULE__.import(contents, opts))

  @doc """
  Compiles decoded import data and raises on failure.
  """
  @spec load!(map(), [option()]) :: Spec.t()
  def load!(attrs, opts \\ []), do: raise_on_error(load(attrs, opts))

  defp spec_attrs(%AgentDocument{} = document, opts) do
    with {:ok, context_schema} <- resolve_context_schema(document.agent, opts),
         {:ok, result} <- resolve_result(document.agent, opts),
         {:ok, tool_source_data} <- tool_source_data(document.tools, opts),
         {:ok, explicit_operations} <- explicit_operations(document.operations),
         {:ok, controls} <- controls(document.controls, opts) do
      agent = document.agent

      {:ok,
       %{
         id: Schema.get_key(agent, :id),
         model: Schema.get_key(agent, :model),
         generation: Schema.get_key(agent, :generation),
         instructions: Schema.get_key(agent, :instructions, Agent.default_instructions()),
         context_schema: context_schema,
         result: result,
         memory: Schema.get_key(agent, :memory),
         operations: tool_source_data.operations ++ explicit_operations,
         controls: controls,
         runtime_defaults: Schema.get_key(agent, :runtime_defaults, document.runtime_defaults) || %{},
         metadata: import_metadata(document, context_schema, result, tool_source_data.sources, opts)
       }}
    end
  end

  defp normalize_document(%{} = attrs) do
    attrs = stringify_keys(attrs)

    cond do
      is_map(attrs["agent"]) ->
        attrs

      Enum.any?(@agent_keys, &Map.has_key?(attrs, &1)) ->
        {agent, rest} = Map.split(attrs, @agent_keys)
        {document, _ignored} = Map.split(rest, @document_keys)
        Map.put(document, "agent", agent)

      true ->
        attrs
    end
  end

  defp resolve_context_schema(agent, opts) do
    agent
    |> context_schema_ref()
    |> fetch_context_schema_ref(opts)
  end

  defp context_schema_ref(agent) do
    case Schema.get_key(agent, :context) || Schema.get_key(agent, :context_schema) do
      nil ->
        nil

      %{} = context ->
        Schema.get_key(context, :ref) || Schema.get_key(context, :schema_ref) || {:invalid_context_ref, context}

      ref when is_binary(ref) or is_atom(ref) ->
        ref

      other ->
        {:invalid_context_ref, other}
    end
  end

  defp fetch_context_schema_ref(nil, _opts), do: {:ok, nil}
  defp fetch_context_schema_ref({:invalid_context_ref, ref}, _opts), do: {:error, {:invalid_context_ref, ref}}
  defp fetch_context_schema_ref(ref, opts), do: Registry.fetch(:context_schemas, ref, opts)

  defp resolve_result(agent, opts) do
    case Schema.get_key(agent, :result) || Schema.get_key(agent, :result_schema) do
      nil ->
        {:ok, nil}

      %{} = result ->
        resolve_result_map(result, opts)

      ref when is_binary(ref) or is_atom(ref) ->
        with {:ok, schema} <- Registry.fetch(:result_schemas, ref, opts) do
          Spec.Result.new(
            schema: schema,
            metadata: %{"schema_ref" => to_string(ref)}
          )
        end

      other ->
        {:error, {:invalid_result_ref, other}}
    end
  end

  defp resolve_result_map(result, opts) do
    case Schema.get_key(result, :ref) || Schema.get_key(result, :schema_ref) do
      nil ->
        {:error, {:invalid_result_ref, result}}

      ref ->
        with {:ok, schema} <- Registry.fetch(:result_schemas, ref, opts) do
          Spec.Result.new(
            schema: schema,
            max_repairs: Schema.get_key(result, :max_repairs, 1),
            metadata:
              result
              |> Schema.get_key(:metadata, %{})
              |> stringify_keys()
              |> Map.put("schema_ref", to_string(ref))
          )
        end
    end
  end

  defp tool_source_data(tools, opts) when is_map(tools) do
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
    |> tool_entries(:actions, :action)
    |> Enum.reduce_while({:ok, []}, fn action_ref, {:ok, operations} ->
      with {:ok, action} <- resolve_action(action_ref, opts),
           {:ok, operation} <- operation_from_action(action) do
        {:cont, {:ok, [operation | operations]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_result()
  end

  defp ash_resource_operations(tools, opts) when is_map(tools) do
    tools
    |> tool_entries(:ash_resources, :ash_resource)
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
    |> tool_entries(:browsers, :browser)
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
    |> tool_entries(:mcp_tools, :mcp_tool)
    |> Enum.reduce_while({:ok, [], []}, fn mcp_ref, {:ok, acc_operations, sources} ->
      with {:ok, source} <- normalize_mcp_ref(mcp_ref),
           {:ok, source_operations} <- Source.operations(source) do
        source_metadata = %{
          "source" => "mcp",
          "endpoint" => metadata_value(source.endpoint),
          "prefix" => source.prefix,
          "required" => source.required,
          "transport" => metadata_value(source.transport),
          "client_info" => source.client_info,
          "protocol_version" => source.protocol_version,
          "capabilities" => source.capabilities,
          "timeouts" => source.timeouts,
          "tools" => Enum.map(source.tools, & &1.name)
        }

        {:cont, {:ok, acc_operations ++ source_operations, sources ++ [reject_nil_values(source_metadata)]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp catalog_operations(tools, opts) when is_map(tools) do
    tools
    |> tool_entries(:catalogs, :catalog)
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

        {:cont, {:ok, acc_operations ++ source_operations, sources ++ [reject_nil_values(source_metadata)]}}
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

  defp resolve_action(ref, opts) when is_binary(ref) do
    case Registry.fetch(:actions, ref, opts) do
      {:ok, action} -> {:ok, action}
      {:error, reason} -> {:error, reason}
    end
  end

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
        idempotency: resource_data.idempotency || operation.idempotency,
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
        idempotency: browser.idempotency || operation.idempotency,
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
    attrs = stringify_keys(attrs)

    with {:ok, resource} <-
           resolve_ash_resource(
             Schema.get_key(attrs, :resource) || Schema.get_key(attrs, :ref),
             opts
           ),
         {:ok, actions} <-
           normalize_name_list(Schema.get_key(attrs, :actions, []), :ash_resource_actions),
         {:ok, idempotency} <-
           normalize_idempotency(Schema.get_key(attrs, :idempotency, :idempotent)),
         {:ok, metadata} <- normalize_metadata(Schema.get_key(attrs, :metadata, %{})) do
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

  defp normalize_ash_resource_ref(ref, opts) do
    normalize_ash_resource_ref(%{"resource" => ref}, opts)
  end

  defp resolve_ash_resource(nil, _opts), do: {:error, :missing_ash_resource_ref}

  defp resolve_ash_resource(resource, _opts) when is_atom(resource) and not is_nil(resource),
    do: {:ok, resource}

  defp resolve_ash_resource(ref, opts) when is_binary(ref),
    do: Registry.fetch(:ash_resources, ref, opts)

  defp resolve_ash_resource(other, _opts), do: {:error, {:invalid_ash_resource_ref, other}}

  defp normalize_browser_ref(%{} = attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, name} <-
           normalize_name(Schema.get_key(attrs, :name) || Schema.get_key(attrs, :ref)),
         {:ok, mode} <- Jidoka.Browser.normalize_mode(Schema.get_key(attrs, :mode, :read_only)),
         {:ok, allow} <- normalize_string_list(Schema.get_key(attrs, :allow, []), :browser_allow),
         {:ok, idempotency} <-
           normalize_idempotency(Schema.get_key(attrs, :idempotency, :idempotent)),
         {:ok, metadata} <- normalize_metadata(Schema.get_key(attrs, :metadata, %{})) do
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
    attrs = stringify_keys(attrs)

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
    attrs = stringify_keys(attrs)

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

  defp tool_entries(tools, plural_key, singular_key) do
    tools
    |> first_value([plural_key, singular_key])
    |> List.wrap()
  end

  defp first_value(map, keys) do
    Enum.find_value(keys, [], fn key ->
      case Schema.fetch_key(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result({:error, reason}), do: {:error, reason}

  defp explicit_operations(operations) when is_list(operations) do
    operations
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, operations} ->
      attrs = normalize_operation_attrs(attrs)

      case Spec.Operation.new(attrs) do
        {:ok, operation} -> {:cont, {:ok, [operation | operations]}}
        {:error, reason} -> {:halt, {:error, {:invalid_operation, attrs, reason}}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_operation_attrs(%{} = attrs) do
    stringify_keys(attrs)
  end

  defp normalize_operation_attrs(attrs), do: attrs

  defp controls(controls, opts) when is_map(controls) do
    with :ok <- reject_legacy_result_controls(controls),
         {:ok, inputs} <-
           boundary_controls(
             controls,
             opts,
             [:inputs, :input],
             Controls.Input,
             :invalid_input_control
           ),
         {:ok, operations} <- operation_controls(controls, opts),
         {:ok, outputs} <-
           boundary_controls(
             controls,
             opts,
             [:outputs, :output],
             Controls.Output,
             :invalid_output_control
           ) do
      Controls.new(
        max_turns: Schema.get_key(controls, :max_turns),
        timeout_ms: Schema.get_key(controls, :timeout_ms) || Schema.get_key(controls, :timeout),
        inputs: inputs,
        operations: operations,
        outputs: outputs
      )
    end
  end

  defp reject_legacy_result_controls(controls) do
    cond do
      match?({:ok, _value}, Schema.fetch_key(controls, :result)) ->
        {:error, {:unsupported_control_key, :result, :output}}

      match?({:ok, _value}, Schema.fetch_key(controls, :results)) ->
        {:error, {:unsupported_control_key, :results, :outputs}}

      true ->
        :ok
    end
  end

  defp boundary_controls(controls, opts, keys, module, reason) do
    controls
    |> first_control_entries(keys)
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, boundary_controls} ->
      case boundary_control(attrs, opts, module, reason) do
        {:ok, boundary_control} -> {:cont, {:ok, [boundary_control | boundary_controls]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, boundary_controls} -> {:ok, Enum.reverse(boundary_controls)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp first_control_entries(controls, keys) when is_list(keys) do
    Enum.reduce_while(keys, [], fn key, default ->
      case Schema.fetch_key(controls, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, default}
      end
    end)
  end

  defp operation_controls(controls, opts) do
    controls
    |> first_control_entries([:operations, :operation])
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, operations} ->
      case control_operation(attrs, opts) do
        {:ok, operation} -> {:cont, {:ok, [operation | operations]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp boundary_control(%{} = attrs, opts, module, _reason) do
    attrs = stringify_keys(attrs)

    with {:ok, control} <-
           resolve_control(Schema.get_key(attrs, :control) || Schema.get_key(attrs, :ref), opts) do
      module.new(
        control: control,
        metadata: Schema.get_key(attrs, :metadata, %{})
      )
    end
  end

  defp boundary_control(other, _opts, _module, reason), do: {:error, {reason, other}}

  defp control_operation(%{} = attrs, opts) do
    attrs = stringify_keys(attrs)

    with {:ok, control} <-
           resolve_control(Schema.get_key(attrs, :control) || Schema.get_key(attrs, :ref), opts) do
      Controls.Operation.new(
        control: control,
        match: Schema.get_key(attrs, :when) || Schema.get_key(attrs, :match) || %{},
        metadata: Schema.get_key(attrs, :metadata, %{})
      )
    end
  end

  defp control_operation(other, _opts), do: {:error, {:invalid_operation_control, other}}

  defp resolve_control(nil, _opts), do: {:error, :missing_control_ref}

  defp resolve_control(control, _opts) when is_atom(control) and not is_nil(control) do
    case Jidoka.Control.validate_module(control) do
      :ok -> {:ok, control}
      {:error, message} -> {:error, {:invalid_control_module, control, message}}
    end
  end

  defp resolve_control(ref, opts) when is_binary(ref), do: Registry.fetch(:controls, ref, opts)

  defp resolve_control(other, _opts), do: {:error, {:invalid_control_ref, other}}

  defp validate_operation_names(operations) do
    duplicates =
      operations
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> name end)

    case duplicates do
      [] -> :ok
      [name | _rest] -> {:error, {:duplicate_operation, name}}
    end
  end

  defp normalize_name(value) when is_atom(value) and not is_nil(value) do
    value
    |> Atom.to_string()
    |> normalize_name()
  end

  defp normalize_name(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, value) do
      {:ok, value}
    else
      {:error, {:invalid_lower_snake_name, value}}
    end
  end

  defp normalize_name(value), do: {:error, {:invalid_name, value}}

  defp normalize_name_list(nil, _field), do: {:ok, []}

  defp normalize_name_list(values, field) when is_list(values) do
    normalize_list(values, &normalize_name/1, field)
  end

  defp normalize_name_list(value, field), do: normalize_name_list([value], field)

  defp normalize_string_list(nil, _field), do: {:ok, []}

  defp normalize_string_list(values, field) when is_list(values) do
    normalize_list(values, &normalize_string/1, field)
  end

  defp normalize_string_list(value, field), do: normalize_string_list([value], field)

  defp normalize_string(value) when is_atom(value) and not is_nil(value),
    do: {:ok, Atom.to_string(value)}

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_empty_string, value}}
      value -> {:ok, value}
    end
  end

  defp normalize_string(value), do: {:error, {:invalid_string, value}}

  defp normalize_list(values, fun, field) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, values} ->
      case fun.(value) do
        {:ok, value} -> {:cont, {:ok, values ++ [value]}}
        {:error, reason} -> {:halt, {:error, {field, reason}}}
      end
    end)
  end

  defp normalize_idempotency(value) when is_atom(value) do
    if value in Spec.Operation.valid_idempotencies() do
      {:ok, value}
    else
      {:error, {:invalid_idempotency, value}}
    end
  end

  defp normalize_idempotency(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    Spec.Operation.valid_idempotencies()
    |> Enum.find(&(Atom.to_string(&1) == normalized))
    |> case do
      nil -> {:error, {:invalid_idempotency, value}}
      idempotency -> {:ok, idempotency}
    end
  end

  defp normalize_idempotency(value), do: {:error, {:invalid_idempotency, value}}

  defp normalize_metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  defp normalize_metadata(metadata), do: {:error, {:invalid_metadata, metadata}}

  defp metadata_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp metadata_value(value) when is_tuple(value), do: inspect(value)
  defp metadata_value(value), do: value

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp import_metadata(%AgentDocument{} = document, context_schema, result, tool_sources, opts) do
    document.metadata
    |> stringify_keys()
    |> Map.put("source", "import")
    |> Map.put("import_version", document.version)
    |> Map.put("context_schema?", not is_nil(context_schema))
    |> Map.put("result_schema?", not is_nil(result))
    |> maybe_put_tool_sources(tool_sources)
    |> maybe_put_source(Keyword.get(opts, :source))
  end

  defp maybe_put_tool_sources(metadata, []), do: metadata

  defp maybe_put_tool_sources(metadata, tool_sources),
    do: Map.put(metadata, "tool_sources", tool_sources)

  defp maybe_put_source(metadata, nil), do: metadata
  defp maybe_put_source(metadata, source), do: Map.put(metadata, "source_ref", source)

  defp string_format(contents, opts) do
    case Keyword.get(opts, :format) || detect_string_format(contents) do
      format when format in [:json, :yaml] -> {:ok, format}
      other -> {:error, {:unsupported_import_format, other}}
    end
  end

  defp detect_string_format(contents) do
    case String.trim_leading(contents) do
      <<"{" <> _rest>> -> :json
      <<"[" <> _rest>> -> :json
      _other -> :yaml
    end
  end

  defp decode_string(contents, :json), do: Jason.decode(contents)

  defp decode_string(contents, :yaml),
    do: YamlElixir.read_from_string(contents, merge_anchors: true)

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {stringify_key(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: key

  defp import_error(reason, details \\ []) do
    Error.validation_error("Invalid Jidoka import document.",
      field: Keyword.get(details, :field, :document),
      value: Keyword.get(details, :value),
      details: %{reason: reason}
    )
  end

  defp raise_on_error({:ok, spec}), do: spec
  defp raise_on_error({:error, error}) when is_exception(error), do: raise(error)
  defp raise_on_error({:error, reason}), do: raise(ArgumentError, inspect(reason))
end
