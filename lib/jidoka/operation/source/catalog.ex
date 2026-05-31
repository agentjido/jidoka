defmodule Jidoka.Operation.Source.Catalog do
  @moduledoc """
  Operation source backed by the Jido action discovery catalog.

  A catalog source publishes one lookup operation. That operation returns
  discovered Jido actions filtered by query, provider/category/tag, allowlist,
  and denylist. It does not execute discovered actions.
  """

  @behaviour Jidoka.Operation.Source

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect

  @type t :: %__MODULE__{
          name: String.t(),
          via: term(),
          providers: [String.t()],
          only: [String.t()],
          except: [String.t()],
          max_results: pos_integer() | nil,
          description: String.t() | nil,
          idempotency: Operation.idempotency(),
          metadata: map()
        }

  defstruct [
    :name,
    :via,
    providers: [],
    only: [],
    except: [],
    max_results: nil,
    description: nil,
    idempotency: :idempotent,
    metadata: %{}
  ]

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Jidoka.Schema.normalize_attrs(attrs)

    with {:ok, name} <- normalize_name(Jidoka.Schema.get_key(attrs, :name), "catalog name"),
         {:ok, via} <- normalize_via(Jidoka.Schema.get_key(attrs, :via, :jido_discovery)),
         {:ok, providers} <-
           normalize_string_list(
             Jidoka.Schema.get_key(attrs, :providers, []),
             "catalog providers"
           ),
         {:ok, only} <-
           normalize_name_list(Jidoka.Schema.get_key(attrs, :only, []), "catalog only list"),
         {:ok, except} <-
           normalize_name_list(Jidoka.Schema.get_key(attrs, :except, []), "catalog except list"),
         {:ok, max_results} <- normalize_max_results(Jidoka.Schema.get_key(attrs, :max_results)),
         {:ok, idempotency} <-
           normalize_idempotency(Jidoka.Schema.get_key(attrs, :idempotency, :idempotent)),
         {:ok, metadata} <- normalize_metadata(Jidoka.Schema.get_key(attrs, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         name: name,
         via: via,
         providers: providers,
         only: only,
         except: except,
         max_results: max_results,
         description: Jidoka.Schema.get_key(attrs, :description),
         idempotency: idempotency,
         metadata: metadata
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
       Operation.new!(
         name: operation_name(source),
         description: source.description || "Search the #{source.name} Jido action catalog.",
         idempotency: source.idempotency,
         metadata:
           source.metadata
           |> Map.merge(%{
             "source" => "catalog",
             "kind" => "catalog",
             "catalog" => source.name,
             "via" => metadata_value(source.via),
             "providers" => source.providers,
             "only" => source.only,
             "except" => source.except,
             "max_results" => source.max_results
           })
           |> reject_nil_values()
       )
     ]}
  end

  @impl true
  def capability(%__MODULE__{} = source, _opts) do
    {:ok,
     fn
       %Effect.Intent{kind: :operation, payload: payload}, %Effect.Journal{} ->
         with {:ok, request} <- Effect.OperationRequest.from_input(payload),
              :ok <- ensure_operation_name(source, request.name),
              {:ok, catalog} <- search_catalog(source, request.arguments) do
           {:ok, catalog}
         end

       %Effect.Intent{kind: kind}, _journal ->
         {:error, {:unsupported_effect_kind, kind}}
     end}
  end

  @spec operation_name(t()) :: String.t()
  def operation_name(%__MODULE__{name: name}), do: "catalog_#{name}"

  defp ensure_operation_name(source, name) do
    expected = operation_name(source)

    if name == expected do
      :ok
    else
      {:error, {:missing_operation_handler, name}}
    end
  end

  defp search_catalog(%__MODULE__{via: via}, _arguments)
       when via not in [:jido_discovery, "jido_discovery", :discovery, "discovery"] do
    {:error, {:unsupported_catalog_source, via}}
  end

  defp search_catalog(%__MODULE__{} = source, arguments) when is_map(arguments) do
    query = arguments |> get_any([:query, "query", :q, "q"]) |> normalize_query()

    limit =
      arguments
      |> get_any([:limit, "limit", :max_results, "max_results"])
      |> runtime_limit(source.max_results)

    actions =
      [limit: nil]
      |> Jido.Discovery.list_actions()
      |> filter_query(query)
      |> filter_providers(source.providers)
      |> filter_only(source.only)
      |> filter_except(source.except)
      |> Enum.take(limit)
      |> Enum.map(&project_action/1)

    {:ok, %{catalog: source.name, query: query, count: length(actions), actions: actions}}
  end

  defp filter_query(actions, nil), do: actions

  defp filter_query(actions, query) do
    query = String.downcase(query)

    Enum.filter(actions, fn action ->
      [action[:name], action[:description], action[:category] && to_string(action[:category])]
      |> Enum.concat(Enum.map(action[:tags] || [], &to_string/1))
      |> Enum.reject(&is_nil/1)
      |> Enum.any?(&String.contains?(String.downcase(&1), query))
    end)
  end

  defp filter_providers(actions, []), do: actions

  defp filter_providers(actions, providers) do
    providers = MapSet.new(Enum.map(providers, &String.downcase/1))

    Enum.filter(actions, fn action ->
      values =
        [action[:category] && to_string(action[:category])]
        |> Enum.concat(Enum.map(action[:tags] || [], &to_string/1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&String.downcase/1)

      Enum.any?(values, &MapSet.member?(providers, &1))
    end)
  end

  defp filter_only(actions, []), do: actions

  defp filter_only(actions, only) do
    allowed = MapSet.new(only)
    Enum.filter(actions, &MapSet.member?(allowed, &1[:name]))
  end

  defp filter_except(actions, []), do: actions

  defp filter_except(actions, except) do
    blocked = MapSet.new(except)
    Enum.reject(actions, &MapSet.member?(blocked, &1[:name]))
  end

  defp project_action(action) do
    %{
      name: action[:name],
      description: action[:description],
      module: inspect(action[:module]),
      slug: action[:slug],
      category: action[:category],
      tags: action[:tags] || []
    }
    |> reject_nil_values()
  end

  defp runtime_limit(nil, nil), do: 10
  defp runtime_limit(nil, default), do: default

  defp runtime_limit(value, default) when is_integer(value),
    do: max(1, value) |> min(default || value)

  defp runtime_limit(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {limit, ""} -> runtime_limit(limit, default)
      _other -> default || 10
    end
  end

  defp runtime_limit(_value, default), do: default || 10

  defp normalize_query(nil), do: nil

  defp normalize_query(query) do
    query
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      query -> query
    end
  end

  defp normalize_via(via), do: {:ok, via}

  defp normalize_max_results(nil), do: {:ok, nil}
  defp normalize_max_results(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp normalize_max_results(value), do: {:error, {:invalid_catalog_max_results, value}}

  defp normalize_idempotency(value) when is_atom(value) do
    if value in Operation.valid_idempotencies() do
      {:ok, value}
    else
      {:error, {:invalid_catalog_idempotency, value}}
    end
  end

  defp normalize_idempotency(value) when is_binary(value) do
    value = String.trim(value)

    Operation.valid_idempotencies()
    |> Enum.find(&(Atom.to_string(&1) == value))
    |> case do
      nil -> {:error, {:invalid_catalog_idempotency, value}}
      value -> {:ok, value}
    end
  end

  defp normalize_idempotency(value), do: {:error, {:invalid_catalog_idempotency, value}}

  defp normalize_metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  defp normalize_metadata(metadata), do: {:error, {:invalid_catalog_metadata, metadata}}

  defp normalize_name(value, label) when is_atom(value) and not is_nil(value) do
    value |> Atom.to_string() |> normalize_name(label)
  end

  defp normalize_name(value, label) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, value) do
      {:ok, value}
    else
      {:error, {label_key(label), :not_lower_snake, value}}
    end
  end

  defp normalize_name(value, label),
    do: {:error, {label_key(label), value}}

  defp label_key("catalog name"), do: :catalog_name
  defp label_key("catalog only list"), do: :catalog_only_list
  defp label_key("catalog except list"), do: :catalog_except_list
  defp label_key(label), do: {:invalid_label, label}

  defp normalize_name_list(nil, _label), do: {:ok, []}

  defp normalize_name_list(values, label) when is_list(values) do
    normalize_list(values, &normalize_name(&1, label))
  end

  defp normalize_name_list(value, label), do: normalize_name_list([value], label)

  defp normalize_string_list(nil, _label), do: {:ok, []}

  defp normalize_string_list(values, label) when is_list(values) do
    normalize_list(values, &normalize_string(&1, label))
  end

  defp normalize_string_list(value, label), do: normalize_string_list([value], label)

  defp normalize_string(value, _label) when is_atom(value) and not is_nil(value),
    do: {:ok, Atom.to_string(value)}

  defp normalize_string(value, label) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_empty_string, label}}
      value -> {:ok, value}
    end
  end

  defp normalize_string(value, label), do: {:error, {:invalid_string, label, value}}

  defp normalize_list(values, fun) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp metadata_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp metadata_value(value) when is_tuple(value), do: inspect(value)
  defp metadata_value(value), do: value

  defp get_any(map, keys), do: Enum.find_value(keys, &Map.get(map, &1))

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
