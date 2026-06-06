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
  alias Jidoka.Operation.Source.Catalog.Normalize
  alias Jidoka.Operation.Source.Catalog.Parameters
  alias Jidoka.Schema
  alias Jidoka.Workflow.Lua

  @default_prefix "catalog_"
  @default_timeout 1_500
  @default_max_calls 12
  @default_max_parallel_calls 8
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

  @schema Zoi.struct(
            __MODULE__,
            %{
              catalog: Zoi.atom() |> Zoi.nullish(),
              prefix: Zoi.string() |> Zoi.default(@default_prefix),
              description: Zoi.string() |> Zoi.nullish(),
              timeout: Zoi.integer() |> Zoi.default(@default_timeout),
              max_calls: Zoi.integer() |> Zoi.default(@default_max_calls),
              max_parallel_calls: Zoi.integer() |> Zoi.default(@default_max_parallel_calls),
              require_read_only?: Zoi.boolean() |> Zoi.default(true),
              result: Schema.atom_enum([:structured]) |> Zoi.default(:structured),
              idempotency: Schema.atom_enum(Operation.valid_idempotencies()) |> Zoi.default(:idempotent),
              metadata: Zoi.map() |> Zoi.default(%{}),
              catalog_value: Zoi.any() |> Zoi.nullish(),
              templates: Zoi.map() |> Zoi.default(%{})
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

    with {:ok, catalog_module} <- Normalize.catalog_module(Schema.get_key(attrs, :catalog)),
         {:ok, catalog_value} <- Normalize.catalog_value(catalog_module),
         {:ok, prefix} <- Normalize.prefix(Schema.get_key(attrs, :prefix, @default_prefix)),
         {:ok, timeout} <- Normalize.positive_integer(Schema.get_key(attrs, :timeout, @default_timeout), :timeout),
         {:ok, max_calls} <-
           Normalize.positive_integer(Schema.get_key(attrs, :max_calls, @default_max_calls), :max_calls),
         {:ok, max_parallel_calls} <-
           Normalize.positive_integer(
             Schema.get_key(attrs, :max_parallel_calls, @default_max_parallel_calls),
             :max_parallel_calls
           ),
         {:ok, require_read_only?} <-
           Normalize.boolean(Schema.get_key(attrs, :require_read_only?, true), :require_read_only?),
         {:ok, result} <- Normalize.result(Schema.get_key(attrs, :result, :structured)),
         {:ok, idempotency} <- Normalize.idempotency(Schema.get_key(attrs, :idempotency, :idempotent)),
         {:ok, metadata} <- Normalize.metadata(Schema.get_key(attrs, :metadata, %{})),
         {:ok, templates} <- Normalize.templates(catalog_module) do
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
    context = opts |> Keyword.get(:context, %{}) |> Normalize.context()

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
          "parameters_schema" => Parameters.schema(suffix)
        })
        |> Normalize.reject_nil_values()
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
    query = arguments |> Normalize.get(:query, "") |> to_string()
    limit = arguments |> Normalize.get(:limit, 5) |> Normalize.positive_integer_or_default(5) |> Normalize.clamp(1, 10)

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
    ids = arguments |> Normalize.get(:ids, []) |> List.wrap() |> Enum.map(&to_string/1)

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
    script = arguments |> Normalize.get(:script, "") |> to_string()
    allowed_tools = arguments |> Normalize.get(:allowed_tools, []) |> List.wrap() |> Enum.map(&to_string/1)

    max_calls =
      arguments
      |> Normalize.get(:max_calls, source.max_calls)
      |> Normalize.positive_integer_or_default(source.max_calls)

    max_parallel_calls =
      arguments
      |> Normalize.get(:max_parallel_calls, source.max_parallel_calls)
      |> Normalize.positive_integer_or_default(source.max_parallel_calls)

    timeout =
      arguments
      |> Normalize.get(:timeout, source.timeout)
      |> Normalize.positive_integer_or_default(source.timeout)

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
      "returns" => Normalize.lua_metadata(entry, "returns"),
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
      "returns" => Normalize.lua_metadata(entry, "returns"),
      "safety" => if(entry.read_only?, do: "read_only", else: "mutating"),
      "example" => Normalize.lua_metadata(entry, "example")
    }
  end

  defp failure_result(script, allowed_tools, reason) do
    %{
      "status" => "failed",
      "script" => script,
      "reason" => Normalize.format_reason(reason),
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
end
