defmodule Jidoka.Operation.Source.Catalog do
  @moduledoc """
  Operation source backed by a `Jido.Action.Catalog`.

  A catalog source exposes one governed model-visible operation family:

    * `<prefix>query`
    * `<prefix>describe`
    * `<prefix>execute`

  The model can search and inspect hidden catalog entries, then execute a
  sandboxed Lua-authored `jidoka.workflow({...})` plan over selected read-only
  actions. The catalog module owns action registration and optional templates;
  Jidoka owns policy, execution, and tracing.
  """

  @behaviour Jidoka.Operation.Source

  alias Jido.Action.Catalog, as: ActionCatalog
  alias Jido.Action.Catalog.Entry
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Schema
  alias Jidoka.Workflow.Lua

  @default_prefix "catalog_"
  @default_timeout 1_500
  @default_max_calls 12
  @default_max_parallel_calls 8
  @result_modes [:structured]

  @type t :: %__MODULE__{
          catalog: module(),
          prefix: String.t(),
          description: String.t() | nil,
          timeout: pos_integer(),
          max_calls: pos_integer(),
          max_parallel_calls: pos_integer(),
          require_read_only?: boolean(),
          result: :structured,
          idempotency: Operation.idempotency(),
          metadata: map(),
          catalog_value: ActionCatalog.t(),
          templates: map()
        }

  defstruct [
    :catalog,
    :description,
    :catalog_value,
    prefix: @default_prefix,
    timeout: @default_timeout,
    max_calls: @default_max_calls,
    max_parallel_calls: @default_max_parallel_calls,
    require_read_only?: true,
    result: :structured,
    idempotency: :idempotent,
    metadata: %{},
    templates: %{}
  ]

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, catalog_module} <- normalize_catalog_module(Schema.get_key(attrs, :catalog)),
         {:ok, catalog_value} <- fetch_catalog(catalog_module),
         {:ok, prefix} <- normalize_prefix(Schema.get_key(attrs, :prefix, @default_prefix)),
         {:ok, timeout} <- normalize_positive_integer(Schema.get_key(attrs, :timeout, @default_timeout), :timeout),
         {:ok, max_calls} <-
           normalize_positive_integer(Schema.get_key(attrs, :max_calls, @default_max_calls), :max_calls),
         {:ok, max_parallel_calls} <-
           normalize_positive_integer(
             Schema.get_key(attrs, :max_parallel_calls, @default_max_parallel_calls),
             :max_parallel_calls
           ),
         {:ok, require_read_only?} <-
           normalize_boolean(Schema.get_key(attrs, :require_read_only?, true), :require_read_only?),
         {:ok, result} <- normalize_result(Schema.get_key(attrs, :result, :structured)),
         {:ok, idempotency} <- normalize_idempotency(Schema.get_key(attrs, :idempotency, :idempotent)),
         {:ok, metadata} <- normalize_metadata(Schema.get_key(attrs, :metadata, %{})),
         {:ok, templates} <- fetch_templates(catalog_module) do
      {:ok,
       %__MODULE__{
         catalog: catalog_module,
         catalog_value: catalog_value,
         prefix: prefix,
         description: Schema.get_key(attrs, :description),
         timeout: timeout,
         max_calls: max_calls,
         max_parallel_calls: max_parallel_calls,
         require_read_only?: require_read_only?,
         result: result,
         idempotency: idempotency,
         metadata: metadata,
         templates: templates
       }}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, source} -> source
      {:error, reason} -> raise ArgumentError, "invalid catalog source: #{inspect(reason)}"
    end
  end

  @impl true
  def operations(%__MODULE__{} = source, _opts) do
    {:ok,
     [
       operation(source, "query", "Search hidden catalog actions available for scripted workflows."),
       operation(source, "describe", "Describe selected hidden catalog actions and workflow templates."),
       operation(source, "execute", "Execute a sandboxed Lua workflow over selected catalog actions.")
     ]}
  end

  @impl true
  def capability(%__MODULE__{} = source, opts) do
    context = opts |> Keyword.get(:context, %{}) |> normalize_context()

    {:ok,
     fn
       %Effect.Intent{kind: :operation, payload: payload}, %Effect.Journal{} ->
         with {:ok, request} <- Effect.OperationRequest.from_input(payload) do
           route(source, request.name, request.arguments, context)
         end

       %Effect.Intent{kind: kind}, _journal ->
         {:error, {:unsupported_effect_kind, kind}}
     end}
  end

  defp operation(%__MODULE__{} = source, suffix, description) do
    Operation.new!(
      name: source.prefix <> suffix,
      description: source.description || description,
      idempotency: source.idempotency,
      metadata:
        source.metadata
        |> Map.merge(%{
          "source" => "catalog",
          "kind" => "catalog",
          "catalog" => inspect(source.catalog),
          "catalog_id" => source.catalog_value.id,
          "prefix" => source.prefix,
          "operation" => suffix,
          "timeout" => source.timeout,
          "max_calls" => source.max_calls,
          "max_parallel_calls" => source.max_parallel_calls,
          "require_read_only?" => source.require_read_only?,
          "result" => Atom.to_string(source.result),
          "parameters_schema" => parameters_schema(suffix)
        })
        |> reject_nil_values()
    )
  end

  defp route(%__MODULE__{} = source, name, arguments, context) do
    cond do
      name == source.prefix <> "query" ->
        query(source, arguments)

      name == source.prefix <> "describe" ->
        describe(source, arguments)

      name == source.prefix <> "execute" ->
        execute(source, arguments, context)

      true ->
        {:error, {:missing_operation_handler, name}}
    end
  end

  defp query(%__MODULE__{} = source, arguments) do
    query = arguments |> get(:query, "") |> to_string()
    limit = arguments |> get(:limit, 5) |> to_integer(5) |> clamp(1, 10)

    with {:ok, hits} <- ActionCatalog.search(source.catalog_value, query_attrs(source, query, limit)) do
      {:ok,
       %{
         "query" => query,
         "count" => length(hits),
         "tools" => Enum.map(hits, &compact_entry(&1.entry)),
         "notice" => "Catalog metadata only. No hidden host tool has run yet, and this output is not business data.",
         "next" => "Call #{source.prefix}describe with the smallest useful set of ids."
       }}
    end
  end

  defp describe(%__MODULE__{} = source, arguments) do
    ids = arguments |> get(:ids, []) |> List.wrap() |> Enum.map(&to_string/1)

    with {:ok, entries} <- fetch_entries(source, ids) do
      {:ok,
       %{
         "tools" => Enum.map(entries, &describe_entry/1),
         "allowed_tools" => ids,
         "templates" => source.templates,
         "notice" =>
           "Catalog metadata only. No hidden host tool has run yet. The next required step is #{source.prefix}execute.",
         "next" => "Call #{source.prefix}execute with a short script that starts with return jidoka.workflow({...})."
       }}
    end
  end

  defp execute(%__MODULE__{} = source, arguments, context) do
    script = arguments |> get(:script, "") |> to_string()
    allowed_tools = arguments |> get(:allowed_tools, []) |> List.wrap() |> Enum.map(&to_string/1)
    max_calls = arguments |> get(:max_calls, source.max_calls) |> to_integer(source.max_calls)

    max_parallel_calls =
      arguments
      |> get(:max_parallel_calls, source.max_parallel_calls)
      |> to_integer(source.max_parallel_calls)

    timeout = arguments |> get(:timeout, source.timeout) |> to_integer(source.timeout)

    result =
      Lua.execute(script,
        catalog: source.catalog_value,
        allowed_tools: allowed_tools,
        context: context,
        max_calls: max_calls,
        max_parallel_calls: max_parallel_calls,
        timeout: timeout,
        require_read_only?: source.require_read_only?
      )

    case result do
      {:ok, result} -> {:ok, result}
      {:error, %{} = result} -> {:ok, repairable_failure(source, result)}
      {:error, reason} -> {:ok, repairable_failure(source, failure_result(script, allowed_tools, reason))}
    end
  end

  defp fetch_entries(%__MODULE__{} = source, ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, entries} ->
      case ActionCatalog.fetch(source.catalog_value, id) do
        {:ok, entry} -> {:cont, {:ok, entries ++ [entry]}}
        {:error, reason} -> {:halt, {:error, {:unknown_catalog_tool, id, reason}}}
      end
    end)
  end

  defp compact_entry(%Entry{} = entry) do
    %{
      "id" => entry.id,
      "name" => entry.name,
      "description" => entry.description,
      "returns" => lua_metadata(entry, "returns"),
      "tags" => entry.tags,
      "read_only" => entry.read_only?
    }
  end

  defp describe_entry(%Entry{} = entry) do
    %{
      "id" => entry.id,
      "name" => entry.name,
      "description" => entry.description,
      "parameters_schema" => entry.input_schema,
      "returns" => lua_metadata(entry, "returns"),
      "safety" => if(entry.read_only?, do: "read_only", else: "mutating"),
      "example" => lua_metadata(entry, "example")
    }
  end

  defp failure_result(script, allowed_tools, reason) do
    %{
      "status" => "failed",
      "script" => script,
      "reason" => format_reason(reason),
      "calls" => [],
      "call_count" => 0,
      "allowed_tools" => allowed_tools
    }
  end

  defp repairable_failure(%__MODULE__{} = source, result) do
    Map.put_new(
      result,
      "next",
      "Fix the Lua script and call #{source.prefix}execute again. The script must start with return jidoka.workflow({...}); do not produce a final answer until status is completed."
    )
  end

  defp normalize_catalog_module(module) when is_atom(module) and not is_nil(module) do
    case Code.ensure_compiled(module) do
      {:module, _module} ->
        if function_exported?(module, :catalog, 0) do
          {:ok, module}
        else
          {:error, {:invalid_catalog_module, module, :missing_catalog_callback}}
        end

      {:error, reason} ->
        {:error, {:invalid_catalog_module, module, reason}}
    end
  end

  defp normalize_catalog_module(module), do: {:error, {:invalid_catalog_module, module}}

  defp fetch_catalog(module) do
    case module.catalog() do
      %ActionCatalog{} = catalog -> {:ok, catalog}
      other -> {:error, {:invalid_catalog_return, module, other}}
    end
  rescue
    exception -> {:error, {:invalid_catalog_return, module, exception}}
  end

  defp fetch_templates(module) do
    if function_exported?(module, :templates, 0) do
      case module.templates() do
        templates when is_map(templates) -> {:ok, stringify_keys(templates)}
        templates -> {:error, {:invalid_catalog_templates, module, templates}}
      end
    else
      {:ok, %{}}
    end
  rescue
    exception -> {:error, {:invalid_catalog_templates, module, exception}}
  end

  defp normalize_prefix(nil), do: {:ok, @default_prefix}

  defp normalize_prefix(prefix) when is_atom(prefix) and not is_nil(prefix),
    do: prefix |> Atom.to_string() |> normalize_prefix()

  defp normalize_prefix(prefix) when is_binary(prefix) do
    prefix = String.trim(prefix)

    cond do
      prefix == "" ->
        {:ok, @default_prefix}

      Regex.match?(~r/^[a-z][a-z0-9_]*_$/, prefix) ->
        {:ok, prefix}

      Regex.match?(~r/^[a-z][a-z0-9_]*$/, prefix) ->
        {:ok, prefix <> "_"}

      true ->
        {:error, {:invalid_catalog_prefix, prefix}}
    end
  end

  defp normalize_prefix(prefix), do: {:error, {:invalid_catalog_prefix, prefix}}

  defp query_attrs(%__MODULE__{} = source, query, limit) do
    attrs = %{
      text: query,
      limit: limit,
      visibility: [:hidden]
    }

    if source.require_read_only? do
      Map.put(attrs, :filters, %{read_only?: true})
    else
      attrs
    end
  end

  defp normalize_positive_integer(value, _field) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp normalize_positive_integer(value, field) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, {:invalid_catalog_positive_integer, field, value}}
    end
  end

  defp normalize_positive_integer(value, field),
    do: {:error, {:invalid_catalog_positive_integer, field, value}}

  defp normalize_boolean(value, _field) when is_boolean(value), do: {:ok, value}
  defp normalize_boolean(value, field), do: {:error, {:invalid_catalog_boolean, field, value}}

  defp normalize_result(result) when result in @result_modes, do: {:ok, result}
  defp normalize_result(result), do: {:error, {:invalid_catalog_result, result}}

  defp normalize_idempotency(idempotency) when is_atom(idempotency) do
    if idempotency in Operation.valid_idempotencies() do
      {:ok, idempotency}
    else
      {:error, {:invalid_catalog_idempotency, idempotency}}
    end
  end

  defp normalize_idempotency(idempotency),
    do: {:error, {:invalid_catalog_idempotency, idempotency}}

  defp normalize_metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  defp normalize_metadata(metadata), do: {:error, {:invalid_catalog_metadata, metadata}}

  defp normalize_context(context) when is_map(context), do: context
  defp normalize_context(context) when is_list(context), do: Map.new(context)
  defp normalize_context(_context), do: %{}

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp to_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp to_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _other -> default
    end
  end

  defp to_integer(_value, default), do: default

  defp clamp(value, min, max), do: value |> Kernel.max(min) |> Kernel.min(max)

  defp lua_metadata(%Entry{metadata: %{"lua" => metadata}}, key), do: Map.get(metadata, key)
  defp lua_metadata(%Entry{metadata: %{lua: metadata}}, key), do: Map.get(metadata, key)
  defp lua_metadata(_entry, _key), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp parameters_schema("query") do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "query" => %{"type" => "string"},
        "limit" => %{"type" => "integer", "default" => 5}
      },
      "required" => ["query"]
    }
  end

  defp parameters_schema("describe") do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "ids" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["ids"]
    }
  end

  defp parameters_schema("execute") do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "script" => %{"type" => "string"},
        "allowed_tools" => %{"type" => "array", "items" => %{"type" => "string"}},
        "max_calls" => %{"type" => "integer"},
        "max_parallel_calls" => %{"type" => "integer"},
        "timeout" => %{"type" => "integer"}
      },
      "required" => ["script", "allowed_tools"]
    }
  end

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
