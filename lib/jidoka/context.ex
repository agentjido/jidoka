defmodule Jidoka.Context do
  @moduledoc """
  Canonical runtime context passed to Jidoka policy code.

  `Jidoka.Context` is the public, data-only shape for controls and approval
  predicates. It keeps application context in `data` and exposes the current
  request, operation, and result metadata without requiring callers to reach
  into turn internals.
  """

  alias Jidoka.Schema

  @boundaries [:input, :operation, :output]
  @operation_kinds [
    :action,
    :operation,
    :tool,
    :ash_resource,
    :browser,
    :skill,
    :mcp,
    :catalog,
    :workflow,
    :subagent,
    :handoff
  ]
  @operation_idempotencies [:pure, :idempotent, :dedupe, :reconcile, :unsafe_once]
  @action_context_namespace :__jidoka__

  @schema Zoi.struct(
            __MODULE__,
            %{
              agent_id: Zoi.string() |> Zoi.nullish(),
              request_id: Zoi.string() |> Zoi.nullish(),
              session_id: Zoi.string() |> Zoi.nullish(),
              loop_index: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish(),
              boundary: Schema.atom_enum(@boundaries) |> Zoi.nullish(),
              control: Zoi.atom() |> Zoi.nullish(),
              control_name: Zoi.string() |> Zoi.nullish(),
              input: Zoi.string() |> Zoi.nullish(),
              data: Zoi.map() |> Zoi.default(%{}),
              runtime: Zoi.map() |> Zoi.default(%{}),
              metadata: Zoi.map() |> Zoi.default(%{}),
              request_metadata: Zoi.map() |> Zoi.default(%{}),
              operation: Zoi.string() |> Zoi.nullish(),
              operation_kind:
                Schema.atom_enum(@operation_kinds)
                |> Zoi.nullish(),
              operation_source: Zoi.string() |> Zoi.nullish(),
              arguments: Zoi.map() |> Zoi.default(%{}),
              operation_metadata: Zoi.map() |> Zoi.default(%{}),
              idempotency:
                Schema.atom_enum(@operation_idempotencies)
                |> Zoi.nullish(),
              idempotency_key: Zoi.string() |> Zoi.nullish(),
              spec: Zoi.any() |> Zoi.nullish(),
              plan: Zoi.any() |> Zoi.nullish(),
              request: Zoi.any() |> Zoi.nullish(),
              agent_state: Zoi.any() |> Zoi.nullish(),
              result: Zoi.any() |> Zoi.nullish(),
              result_value: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type boundary :: :input | :operation | :output
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for runtime context data."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a runtime context from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs =
      attrs
      |> Schema.normalize_attrs()
      |> normalize_context_alias()

    Schema.parse(@schema, attrs)
  end

  @doc "Builds a runtime context and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs |> Schema.normalize_attrs() |> normalize_context_alias(), "context")

  @doc "Normalizes trusted runtime context input and preserves runtime-only fields."
  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = context), do: new(context)
  def from_input(input), do: new(input)

  @doc """
  Builds a request context from caller-provided application data.

  Passing an existing `Jidoka.Context` uses only its public data. Use
  `from_input/1` when trusted code needs to preserve runtime fields.
  """
  @spec from_data(t() | keyword() | map() | nil, keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_data(data, attrs \\ [])

  def from_data(%__MODULE__{} = context, attrs) do
    context
    |> data()
    |> from_data(attrs)
  end

  def from_data(nil, attrs), do: from_data(%{}, attrs)

  def from_data(data, attrs) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, data} <- normalize_data(data) do
      attrs
      |> Map.put(:data, data)
      |> new()
    end
  end

  @doc "Builds a request context from caller-provided application data or raises."
  @spec from_data!(t() | keyword() | map() | nil, keyword() | map()) :: t()
  def from_data!(data, attrs \\ []) do
    case from_data(data, attrs) do
      {:ok, context} -> context
      {:error, reason} -> raise ArgumentError, "invalid context data: #{inspect(reason)}"
    end
  end

  @doc "Projects caller data into the context map expected by Jido actions."
  @spec to_action_context(t()) :: map()
  def to_action_context(%__MODULE__{} = context) do
    context
    |> data()
    |> Map.drop([:__struct__, @action_context_namespace, Atom.to_string(@action_context_namespace)])
    |> Map.put(@action_context_namespace, %{context: context})
  end

  @doc "Fetches an application context value by atom or string key without creating atoms."
  @spec fetch(t() | map(), atom() | String.t()) :: {:ok, term()} | :error
  def fetch(%__MODULE__{data: data}, key), do: fetch_any(data, key)
  def fetch(context, key) when is_map(context), do: fetch_any(context, key)

  @doc "Returns an application context value by atom or string key without creating atoms."
  @spec get(t() | map(), atom() | String.t(), term()) :: term()
  def get(context, key, default \\ nil) when is_map(context) do
    case fetch(context, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc "Returns caller-provided application context data."
  @spec data(t()) :: map()
  def data(%__MODULE__{data: data}), do: data

  @doc "Returns trusted runtime-only context values."
  @spec runtime(t()) :: map()
  def runtime(%__MODULE__{runtime: runtime}), do: runtime

  @doc "Fetches a runtime-only value by atom or string key without creating atoms."
  @spec fetch_runtime(t() | map(), atom() | String.t()) :: {:ok, term()} | :error
  def fetch_runtime(%__MODULE__{runtime: runtime}, key), do: fetch_any(runtime, key)

  def fetch_runtime(%{@action_context_namespace => %{context: %__MODULE__{} = context}}, key),
    do: fetch_runtime(context, key)

  def fetch_runtime(context, _key) when is_map(context), do: :error

  @doc "Returns a runtime-only value by atom or string key without creating atoms."
  @spec get_runtime(t() | map(), atom() | String.t(), term()) :: term()
  def get_runtime(context, key, default \\ nil) when is_map(context) do
    case fetch_runtime(context, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc "Drops runtime-only values before persisting or projecting context."
  @spec sanitize(t()) :: t()
  def sanitize(%__MODULE__{} = context), do: %__MODULE__{context | runtime: %{}}

  defp normalize_context_alias(%{} = attrs) do
    attrs
    |> maybe_put_data_from(:context)
    |> maybe_put_data_from("context")
    |> Map.delete(:context)
    |> Map.delete("context")
  end

  defp normalize_context_alias(attrs), do: attrs

  defp normalize_data(data) when is_list(data) do
    if Keyword.keyword?(data) do
      {:ok, Map.new(data)}
    else
      {:error, {:invalid_context_data, data}}
    end
  end

  defp normalize_data(data) when is_map(data), do: {:ok, data}
  defp normalize_data(data), do: {:error, {:invalid_context_data, data}}

  defp maybe_put_data_from(attrs, key) do
    case {Schema.fetch_key(attrs, :data), Map.fetch(attrs, key)} do
      {:error, {:ok, value}} -> Map.put(attrs, :data, value)
      _other -> attrs
    end
  end

  defp fetch_any(map, key) when is_map(map) do
    Enum.find_value(map, :error, fn {candidate_key, value} ->
      if same_key?(candidate_key, key), do: {:ok, value}
    end)
  end

  defp same_key?(left, right) when is_atom(left) and is_binary(right),
    do: Atom.to_string(left) == right

  defp same_key?(left, right) when is_binary(left) and is_atom(right),
    do: left == Atom.to_string(right)

  defp same_key?(left, right), do: left == right
end
