defmodule Jidoka.Import do
  @moduledoc """
  JSON/YAML import runtime for data-authored Jidoka agents.

  Imports compile into the same `Jidoka.Agent.Spec` contract as the Spark DSL.
  JSON/YAML cannot safely encode executable Elixir values, so action modules and
  context schemas are resolved through caller-provided registries.
  """

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec
  alias Jidoka.Error
  alias Jidoka.Import.AgentDocument
  alias Jidoka.Import.Controls, as: ImportControls
  alias Jidoka.Import.Decoder
  alias Jidoka.Import.Normalize
  alias Jidoka.Import.Registry
  alias Jidoka.Import.Tools
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

  @doc """
  Imports a JSON or YAML agent document string.

  Pass `format: :json` or `format: :yaml` to force a parser. Without a format,
  strings beginning with `{` or `[` are treated as JSON; all others are treated
  as YAML.
  """
  @spec import(String.t(), [option()]) :: {:ok, Spec.t()} | {:error, term()}
  def import(contents, opts \\ []) when is_binary(contents) and is_list(opts) do
    with {:ok, decoded, format} <- Decoder.decode(contents, opts) do
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
         {:ok, tool_source_data} <- Tools.expand(document.tools, opts),
         {:ok, explicit_operations} <- explicit_operations(document.operations),
         {:ok, controls} <- ImportControls.from_import(document.controls, opts) do
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
    attrs = Normalize.stringify_keys(attrs)

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
              |> Normalize.stringify_keys()
              |> Map.put("schema_ref", to_string(ref))
          )
        end
    end
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

  defp normalize_operation_attrs(%{} = attrs), do: Normalize.stringify_keys(attrs)
  defp normalize_operation_attrs(attrs), do: attrs

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

  defp import_metadata(%AgentDocument{} = document, context_schema, result, tool_sources, opts) do
    document.metadata
    |> Normalize.stringify_keys()
    |> Map.put("source", "import")
    |> Map.put("import_version", document.version)
    |> Map.put("context_schema?", not is_nil(context_schema))
    |> Map.put("result_schema?", not is_nil(result))
    |> maybe_put_tool_sources(tool_sources)
    |> maybe_put_source(Keyword.get(opts, :source))
  end

  defp maybe_put_tool_sources(metadata, []), do: metadata
  defp maybe_put_tool_sources(metadata, tool_sources), do: Map.put(metadata, "tool_sources", tool_sources)

  defp maybe_put_source(metadata, nil), do: metadata
  defp maybe_put_source(metadata, source), do: Map.put(metadata, "source_ref", source)

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
