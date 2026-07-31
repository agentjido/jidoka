defmodule Jidoka.Turn.Request do
  @moduledoc "Input for one agent turn."

  alias Jidoka.Agent.State, as: AgentState
  alias Jidoka.ContentPart
  alias Jidoka.Id
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              input: Schema.non_empty_string(),
              content:
                Zoi.array(Zoi.lazy({ContentPart, :schema, []}))
                |> Zoi.default([]),
              request_id: Schema.non_empty_string(),
              agent_state: Zoi.lazy({:"Elixir.Jidoka.Agent.State", :schema, []}),
              context: Zoi.lazy({:"Elixir.Jidoka.Context", :schema, []}),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a turn request."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a turn request and applies runtime identifier defaults."
  @spec new(keyword() | map(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs, opts \\ []) do
    with {:ok, attrs} <- prepare_attrs(attrs, opts) do
      Schema.parse(@schema, attrs)
    end
  end

  @doc "Builds a turn request and raises if the attributes are invalid."
  @spec new!(keyword() | map(), keyword()) :: t()
  def new!(attrs, opts \\ []) do
    case new(attrs, opts) do
      {:ok, request} -> request
      {:error, reason} -> raise ArgumentError, "invalid turn request: #{inspect(reason)}"
    end
  end

  @doc "Normalizes a request struct, text, content-part list, keyword list, or map."
  @spec from_input(t() | String.t() | [ContentPart.input()] | keyword() | map(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def from_input(input, opts \\ [])
  def from_input(%__MODULE__{} = request, opts), do: new(request, opts)
  def from_input(input, opts) when is_binary(input), do: new([input: input], opts)

  def from_input(input, opts) when is_list(input) do
    if Keyword.keyword?(input), do: new(input, opts), else: new(%{content: input}, opts)
  end

  def from_input(input, opts), do: new(input, opts)

  defp prepare_attrs(attrs, opts) do
    attrs = Schema.normalize_attrs(attrs)
    generator = Keyword.get(opts, :id_generator)

    with {:ok, attrs} <- normalize_content(attrs),
         attrs <- put_opt_default(attrs, :request_id, Keyword.get(opts, :request_id)),
         attrs <- put_opt_default(attrs, :context, Keyword.get(opts, :context)),
         attrs <- put_opt_default(attrs, :metadata, Keyword.get(opts, :metadata)),
         {:ok, attrs} <- put_generated_id(attrs, :request_id, "turn", generator),
         {:ok, attrs} <- normalize_context(attrs) do
      {:ok, Schema.put_default(attrs, :agent_state, AgentState.new!())}
    end
  end

  defp normalize_content(attrs) when is_map(attrs) do
    content = Schema.get_key(attrs, :content, [])
    input = Schema.get_key(attrs, :input)

    cond do
      is_list(content) and content != [] -> put_normalized_content(attrs, content, input)
      is_list(input) and input != [] -> put_normalized_content(attrs, input, nil)
      content == [] -> {:ok, put_content(attrs, [])}
      true -> {:error, {:invalid_request_content, content}}
    end
  end

  defp normalize_content(attrs), do: {:error, {:invalid_request_attributes, attrs}}

  defp put_normalized_content(attrs, inputs, input) do
    case ContentPart.from_inputs(inputs) do
      {:ok, content} ->
        input = if is_binary(input), do: input, else: ContentPart.summary(content)

        {:ok,
         attrs
         |> Map.delete("input")
         |> Map.put(:input, input)
         |> put_content(content)}

      {:error, reason} ->
        {:error, {:invalid_request_content, reason}}
    end
  end

  defp put_content(attrs, content) do
    attrs
    |> Map.delete("content")
    |> Map.put(:content, content)
  end

  defp put_opt_default(attrs, _key, nil), do: attrs

  defp put_opt_default(attrs, key, value) do
    string_key = Atom.to_string(key)

    if Map.has_key?(attrs, key) or Map.has_key?(attrs, string_key) do
      attrs
    else
      Map.put(attrs, key, value)
    end
  end

  defp put_generated_id(attrs, key, prefix, generator) do
    if Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key)) do
      {:ok, attrs}
    else
      with {:ok, id} <- Id.generate(prefix, generator) do
        {:ok, Map.put(attrs, key, id)}
      end
    end
  end

  defp normalize_context(attrs) do
    context = Map.get(attrs, :context, Map.get(attrs, "context", %{}))
    request_id = Map.get(attrs, :request_id, Map.get(attrs, "request_id"))
    metadata = Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{}))

    with {:ok, context} <-
           Jidoka.Context.from_data(context,
             request_id: request_id,
             request_metadata: metadata
           ) do
      {:ok,
       attrs
       |> Map.delete("context")
       |> Map.put(:context, context)}
    end
  end
end
