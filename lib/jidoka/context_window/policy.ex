defmodule Jidoka.ContextWindow.Policy do
  @moduledoc """
  Deterministic input-budget policy for model prompt projection.

  `input_budget` is the maximum estimated input-token count. The estimator is
  provider-neutral and uses one token for each four encoded UTF-8 bytes.
  `output_reserve` records output capacity that must remain outside the input
  budget. When the model only declares a total context limit, Jidoka subtracts
  this reserve to derive the input budget.
  """

  alias Jidoka.Agent
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              input_budget: Zoi.integer() |> Zoi.positive() |> Zoi.nullish(),
              output_reserve: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              minimum_recent_turns: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(2),
              bytes_per_token: Zoi.integer() |> Zoi.positive() |> Zoi.default(4)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a context-window policy."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a validated context-window policy."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ []) do
    attrs = attrs |> Schema.normalize_attrs() |> normalize_aliases()
    Schema.parse(@schema, attrs)
  end

  @doc "Builds a context-window policy and raises for invalid data."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ []) do
    case new(attrs) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "invalid context-window policy: #{inspect(reason)}"
    end
  end

  @doc "Resolves policy defaults from an agent specification and model limits."
  @spec resolve(Agent.Spec.t()) :: {:ok, t()} | {:error, term()}
  def resolve(%Agent.Spec{} = spec) do
    with {:ok, configured} <- configured_policy(spec.runtime_defaults),
         output_reserve = configured_value(configured, :output_reserve, generation_reserve(spec)),
         {:ok, configured} <- new(Map.put(configured, :output_reserve, output_reserve)),
         {:ok, input_budget} <- resolved_input_budget(configured, spec.model) do
      new(%{configured | input_budget: input_budget})
    end
  end

  defp configured_policy(defaults) when is_map(defaults) do
    configured =
      defaults
      |> Schema.get_key(:context_policy, Schema.get_key(defaults, :context_window, %{}))
      |> Schema.normalize_attrs()
      |> normalize_aliases()

    if is_map(configured),
      do: {:ok, configured},
      else: {:error, {:invalid_context_policy, configured}}
  end

  defp configured_policy(_defaults), do: {:ok, %{}}

  defp configured_value(configured, key, fallback) do
    case Schema.get_key(configured, key) do
      nil -> fallback
      value -> value
    end
  end

  defp generation_reserve(%Agent.Spec{generation: %{params: params}}) do
    case Schema.get_key(params, :max_tokens) do
      value when is_integer(value) and value >= 0 -> value
      _value -> 0
    end
  end

  defp resolved_input_budget(%__MODULE__{} = policy, model) do
    with {:ok, model_budget} <- model_input_budget(model, policy.output_reserve) do
      {:ok, minimum_budget(policy.input_budget, model_budget)}
    end
  end

  defp model_input_budget(%{limits: nil}, _output_reserve), do: {:ok, nil}

  defp model_input_budget(%{limits: limits}, output_reserve) when is_map(limits) do
    input = Schema.get_key(limits, :input)
    context = Schema.get_key(limits, :context)

    context_input =
      case context do
        value when is_integer(value) and value > output_reserve -> value - output_reserve
        nil -> nil
        value when is_integer(value) -> {:error, {:output_reserve_exceeds_context, output_reserve, value}}
      end

    case context_input do
      {:error, _reason} = error -> error
      value -> {:ok, minimum_budget(input, value)}
    end
  end

  defp model_input_budget(_model, _output_reserve), do: {:ok, nil}

  defp minimum_budget(nil, nil), do: nil
  defp minimum_budget(nil, right), do: right
  defp minimum_budget(left, nil), do: left
  defp minimum_budget(left, right), do: min(left, right)

  defp normalize_aliases(attrs) when is_map(attrs) do
    attrs
    |> put_alias(:input_budget, [:max_input_tokens])
    |> put_alias(:output_reserve, [:output_reserve_tokens])
    |> put_alias(:minimum_recent_turns, [:min_recent_turns])
  end

  defp normalize_aliases(attrs), do: attrs

  defp put_alias(attrs, target, aliases) do
    if Map.has_key?(attrs, target) do
      attrs
    else
      case Enum.find_value(aliases, &alias_value(attrs, &1)) do
        nil -> attrs
        value -> Map.put(attrs, target, value)
      end
    end
  end

  defp alias_value(attrs, alias_key) do
    Map.get(attrs, alias_key, Map.get(attrs, Atom.to_string(alias_key)))
  end
end
