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
  alias Jidoka.Runtime.JidoActions
  alias Jidoka.Schema

  @type format :: :json | :yaml
  @type registry :: keyword() | map()
  @type option ::
          {:format, format()}
          | {:registries, registry()}
          | {:actions, registry()}
          | {:action_registry, registry()}
          | {:controls, registry()}
          | {:control_registry, registry()}
          | {:context_schemas, registry()}
          | {:context_schema_registry, registry()}
          | {:result_schemas, registry()}
          | {:result_schema_registry, registry()}

  @agent_keys ~w(id model generation instructions context context_schema result result_schema memory runtime_defaults metadata)
  @document_keys ~w(version agent tools controls operations runtime_defaults metadata)

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
         {:ok, action_operations} <- action_operations(document.tools, opts),
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
         operations: action_operations ++ explicit_operations,
         controls: controls,
         runtime_defaults:
           Schema.get_key(agent, :runtime_defaults, document.runtime_defaults) || %{},
         metadata: import_metadata(document, context_schema, result, opts)
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
    case Schema.get_key(agent, :context) || Schema.get_key(agent, :context_schema) do
      nil ->
        {:ok, nil}

      %{} = context ->
        case Schema.get_key(context, :ref) || Schema.get_key(context, :schema_ref) do
          nil -> {:error, {:invalid_context_ref, context}}
          ref -> fetch_registry(:context_schemas, ref, opts)
        end

      ref when is_binary(ref) or is_atom(ref) ->
        fetch_registry(:context_schemas, ref, opts)

      other ->
        {:error, {:invalid_context_ref, other}}
    end
  end

  defp resolve_result(agent, opts) do
    case Schema.get_key(agent, :result) || Schema.get_key(agent, :result_schema) do
      nil ->
        {:ok, nil}

      %{} = result ->
        resolve_result_map(result, opts)

      ref when is_binary(ref) or is_atom(ref) ->
        with {:ok, schema} <- fetch_registry(:result_schemas, ref, opts) do
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
        with {:ok, schema} <- fetch_registry(:result_schemas, ref, opts) do
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

  defp action_operations(tools, opts) when is_map(tools) do
    tools
    |> Schema.get_key(:actions, [])
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn action_ref, {:ok, operations} ->
      with {:ok, action} <- resolve_action(action_ref, opts),
           {:ok, operation} <- operation_from_action(action) do
        {:cont, {:ok, [operation | operations]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      {:error, reason} -> {:error, reason}
    end
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
    case fetch_registry(:actions, ref, opts) do
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
             Controls.Result,
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
      with {:ok, boundary_control} <- boundary_control(attrs, opts, module, reason) do
        {:cont, {:ok, [boundary_control | boundary_controls]}}
      else
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
      with {:ok, operation} <- control_operation(attrs, opts) do
        {:cont, {:ok, [operation | operations]}}
      else
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

  defp resolve_control(ref, opts) when is_binary(ref), do: fetch_registry(:controls, ref, opts)

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

  defp import_metadata(%AgentDocument{} = document, context_schema, result, opts) do
    document.metadata
    |> stringify_keys()
    |> Map.put("source", "import")
    |> Map.put("import_version", document.version)
    |> Map.put("context_schema?", not is_nil(context_schema))
    |> Map.put("result_schema?", not is_nil(result))
    |> maybe_put_source(Keyword.get(opts, :source))
  end

  defp maybe_put_source(metadata, nil), do: metadata
  defp maybe_put_source(metadata, source), do: Map.put(metadata, "source_ref", source)

  defp fetch_registry(name, ref, opts) do
    registry = registry(name, opts)

    case registry_lookup(registry, ref) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:unknown_registry_ref, name, ref}}
    end
  end

  defp registry(:actions, opts) do
    Keyword.get(opts, :actions) ||
      Keyword.get(opts, :action_registry) ||
      nested_registry(opts, :actions) ||
      %{}
  end

  defp registry(:controls, opts) do
    Keyword.get(opts, :controls) ||
      Keyword.get(opts, :control_registry) ||
      nested_registry(opts, :controls) ||
      %{}
  end

  defp registry(:context_schemas, opts) do
    Keyword.get(opts, :context_schemas) ||
      Keyword.get(opts, :context_schema_registry) ||
      nested_registry(opts, :context_schemas) ||
      %{}
  end

  defp registry(:result_schemas, opts) do
    Keyword.get(opts, :result_schemas) ||
      Keyword.get(opts, :result_schema_registry) ||
      nested_registry(opts, :result_schemas) ||
      %{}
  end

  defp nested_registry(opts, key) do
    opts
    |> Keyword.get(:registries, %{})
    |> registry_get(key)
  end

  defp registry_lookup(registry, ref) when is_map(registry) do
    registry
    |> Enum.find(fn {key, _value} -> same_ref?(key, ref) end)
    |> case do
      {_key, value} -> {:ok, value}
      nil -> :error
    end
  end

  defp registry_lookup(registry, ref) when is_list(registry) do
    registry
    |> Enum.find(fn {key, _value} -> same_ref?(key, ref) end)
    |> case do
      {_key, value} -> {:ok, value}
      nil -> :error
    end
  end

  defp registry_lookup(_registry, _ref), do: :error

  defp registry_get(registry, key) when is_map(registry) do
    Map.get(registry, key) || Map.get(registry, Atom.to_string(key))
  end

  defp registry_get(registry, key) when is_list(registry) do
    registry
    |> Enum.find(fn {registry_key, _value} -> same_ref?(registry_key, key) end)
    |> case do
      {_registry_key, value} -> value
      nil -> nil
    end
  end

  defp registry_get(_registry, _key), do: nil

  defp same_ref?(left, right) when is_binary(left) and is_binary(right), do: left == right
  defp same_ref?(left, right) when is_atom(left) and is_atom(right), do: left == right

  defp same_ref?(left, right) when is_atom(left) and is_binary(right),
    do: Atom.to_string(left) == right

  defp same_ref?(left, right) when is_binary(left) and is_atom(right),
    do: left == Atom.to_string(right)

  defp same_ref?(_left, _right), do: false

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
