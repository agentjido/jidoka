defmodule Jidoka.Agent.Spec.Generation do
  @moduledoc """
  Provider-facing generation defaults for an agent.

  Generation parameters are intentionally permissive because the supported
  option set varies by model and provider. Jidoka owns the merge shape, while
  ReqLLM/provider clients own final option validation.
  """

  alias Jidoka.Schema

  @known_param_keys [
    :temperature,
    :max_tokens,
    :top_p,
    :presence_penalty,
    :frequency_penalty,
    :tool_choice,
    :system_prompt,
    :timeout,
    :receive_timeout,
    :cache
  ]

  @schema Zoi.struct(
            __MODULE__,
            %{
              params: Zoi.map() |> Zoi.default(%{}),
              provider_options: Zoi.map() |> Zoi.default(%{}),
              extra: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ []), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ []), do: Schema.parse!(@schema, attrs, "generation")

  @spec from_input(t() | keyword() | map() | nil) :: {:ok, t()} | {:error, term()}
  def from_input(nil), do: new()
  def from_input(%__MODULE__{} = generation), do: new(generation)
  def from_input(input) when is_list(input) or is_map(input), do: new(normalize_input(input))

  @spec to_req_llm_opts(t() | keyword() | map() | nil) :: keyword()
  def to_req_llm_opts(input) do
    case from_input(input) do
      {:ok, %__MODULE__{} = generation} ->
        generation.params
        |> to_keyword()
        |> maybe_put_provider_options(generation.provider_options)

      {:error, reason} ->
        raise ArgumentError, "invalid generation: #{inspect(reason)}"
    end
  end

  defp normalize_input(input) do
    attrs = Schema.normalize_attrs(input)

    if Map.has_key?(attrs, :params) or Map.has_key?(attrs, "params") do
      update_params(attrs)
    else
      %{params: normalize_param_keys(attrs)}
    end
  end

  defp update_params(attrs) do
    params = Map.get(attrs, :params, Map.get(attrs, "params", %{}))

    attrs
    |> Map.delete("params")
    |> Map.put(:params, normalize_param_keys(params))
  end

  defp normalize_param_keys(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {normalize_param_key(key), value} end)
  end

  defp normalize_param_keys(params), do: params

  defp normalize_param_key(key) when is_binary(key) do
    Enum.find(@known_param_keys, key, &(Atom.to_string(&1) == key))
  end

  defp normalize_param_key(key), do: key

  defp maybe_put_provider_options(opts, provider_options) when provider_options == %{}, do: opts

  defp maybe_put_provider_options(opts, provider_options),
    do: Keyword.put(opts, :provider_options, provider_options)

  defp to_keyword(map) when is_map(map) do
    Enum.map(map, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    Enum.find(@known_param_keys, &(Atom.to_string(&1) == key)) ||
      raise ArgumentError,
            "generation param #{inspect(key)} is not a known option; put provider-specific values under provider_options"
  end
end
