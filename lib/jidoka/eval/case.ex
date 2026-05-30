defmodule Jidoka.Eval.Case do
  @moduledoc """
  Deterministic evaluation case for one Jidoka turn.

  Eval cases are ordinary data: an agent spec, a turn request, and lightweight
  assertions that can run against fake or live capabilities supplied by the
  caller.
  """

  alias Jidoka.Agent
  alias Jidoka.Id
  alias Jidoka.Schema
  alias Jidoka.Turn

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Schema.non_empty_string(),
              agent: Zoi.lazy({Agent.Spec, :schema, []}),
              request: Zoi.lazy({Turn.Request, :schema, []}),
              assertions: Zoi.map() |> Zoi.default(%{}),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs, opts \\ []) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, id} <- eval_id(attrs, opts),
         {:ok, agent} <- agent(attrs),
         {:ok, request} <- request(attrs, opts) do
      attrs =
        attrs
        |> drop_keys([:id, :agent, :request, :input, :request_id, :agent_state, :context])
        |> Map.put(:id, id)
        |> Map.put(:agent, agent)
        |> Map.put(:request, request)

      Schema.parse(@schema, attrs)
    end
  end

  @spec new!(keyword() | map(), keyword()) :: t()
  def new!(attrs, opts \\ []) do
    case new(attrs, opts) do
      {:ok, eval_case} ->
        eval_case

      {:error, reason} ->
        raise ArgumentError, "invalid eval case: #{inspect(reason)}"
    end
  end

  @spec from_input(t() | keyword() | map(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_input(input, opts \\ [])
  def from_input(%__MODULE__{} = eval_case, opts), do: new(eval_case, opts)
  def from_input(input, opts), do: new(input, opts)

  defp eval_id(attrs, opts) do
    case Schema.fetch_key(attrs, :id) do
      {:ok, id} when is_binary(id) and id != "" -> {:ok, id}
      {:ok, id} -> {:error, {:invalid_eval_case_id, id}}
      :error -> Id.generate("eval", Keyword.get(opts, :id_generator))
    end
  end

  defp agent(attrs) do
    case Schema.fetch_key(attrs, :agent) do
      {:ok, agent} -> Agent.Spec.from_input(agent)
      :error -> {:error, :missing_eval_agent}
    end
  end

  defp request(attrs, opts) do
    request_opts = Keyword.take(opts, [:id_generator])

    case Schema.fetch_key(attrs, :request) do
      {:ok, request} ->
        Turn.Request.from_input(request, request_opts)

      :error ->
        attrs
        |> request_attrs()
        |> Turn.Request.from_input(request_opts)
    end
  end

  defp request_attrs(attrs) do
    [:input, :request_id, :agent_state, :context, :metadata]
    |> Enum.reduce(%{}, fn key, request ->
      case Schema.fetch_key(attrs, key) do
        {:ok, value} -> Map.put(request, key, value)
        :error -> request
      end
    end)
  end

  defp drop_keys(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, attrs ->
      attrs
      |> Map.delete(key)
      |> Map.delete(Atom.to_string(key))
    end)
  end
end
