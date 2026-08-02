defmodule Jidoka.ContentPart do
  @moduledoc """
  Provider-neutral text and media content for requests, messages, and results.

  Media parts use one source: `{:url, url}`, `{:data, binary}`, or
  `{:file_id, id}`. The durable struct keeps the source value. Public
  projections omit the value and show only its kind and safe size data.
  """

  alias Jidoka.Portable
  alias Jidoka.Schema

  @types [:text, :image, :audio, :video, :document]
  @media_types @types -- [:text]
  @default_media_types %{
    image: "image/png",
    audio: "audio/mpeg",
    video: "video/mp4",
    document: "application/octet-stream"
  }

  @schema Zoi.struct(
            __MODULE__,
            %{
              type: Schema.atom_enum(@types),
              text: Zoi.string() |> Zoi.nullish(),
              url: Zoi.string() |> Zoi.nullish(),
              data: Zoi.any() |> Zoi.nullish(),
              file_id: Zoi.string() |> Zoi.nullish(),
              media_type: Zoi.string() |> Zoi.nullish(),
              filename: Zoi.string() |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type content_type :: :text | :image | :audio | :video | :document
  @type source :: {:url, String.t()} | {:data, binary()} | {:file_id, String.t()}
  @type input :: t() | keyword() | map()
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a content part."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the supported content types."
  @spec types() :: [content_type()]
  def types, do: @types

  @doc "Builds a content part from a keyword list or map."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = attrs |> Schema.normalize_attrs() |> put_default_media_type()

    with {:ok, %__MODULE__{} = part} <- Schema.parse(@schema, attrs),
         :ok <- validate(part) do
      {:ok, part}
    end
  end

  @doc "Builds a content part and raises if it is not valid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, part} -> part
      {:error, reason} -> raise ArgumentError, "invalid content part: #{inspect(reason)}"
    end
  end

  @doc "Normalizes a content part struct, keyword list, or map."
  @spec from_input(input()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = part), do: new(part)
  def from_input(input), do: new(input)

  @doc "Normalizes an ordered content-part list."
  @spec from_inputs([input()]) :: {:ok, [t()]} | {:error, term()}
  def from_inputs(inputs) when is_list(inputs) and inputs != [] do
    inputs
    |> Enum.reduce_while({:ok, []}, fn input, {:ok, parts} ->
      case from_input(input) do
        {:ok, part} -> {:cont, {:ok, [part | parts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  def from_inputs(inputs), do: {:error, {:invalid_content_parts, inputs}}

  @doc "Builds a text part."
  @spec text(String.t(), keyword()) :: t()
  def text(text, opts \\ []) when is_binary(text) do
    new!(type: :text, text: text, metadata: Keyword.get(opts, :metadata, %{}))
  end

  @doc "Builds an image part."
  @spec image(source(), keyword()) :: t()
  def image(source, opts \\ []), do: media!(:image, source, opts)

  @doc "Builds an audio part."
  @spec audio(source(), keyword()) :: t()
  def audio(source, opts \\ []), do: media!(:audio, source, opts)

  @doc "Builds a video part."
  @spec video(source(), keyword()) :: t()
  def video(source, opts \\ []), do: media!(:video, source, opts)

  @doc "Builds a document part."
  @spec document(source(), keyword()) :: t()
  def document(source, opts \\ []), do: media!(:document, source, opts)

  @doc "Returns the text in an ordered part list."
  @spec text_content([t()]) :: String.t()
  def text_content(parts) when is_list(parts) do
    parts
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("\n", & &1.text)
    |> String.trim()
  end

  @doc "Returns a non-empty text summary for controls, memory, and debugging."
  @spec summary([t()]) :: String.t()
  def summary(parts) when is_list(parts) do
    case text_content(parts) do
      "" -> "[Multimodal input: #{parts |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.join(", ")}]"
      text -> text
    end
  end

  @doc "Returns the source kind for a media part."
  @spec source_kind(t()) :: :text | :url | :data | :file_id
  def source_kind(%__MODULE__{type: :text}), do: :text
  def source_kind(%__MODULE__{url: url}) when is_binary(url), do: :url
  def source_kind(%__MODULE__{data: data}) when is_binary(data), do: :data
  def source_kind(%__MODULE__{file_id: file_id}) when is_binary(file_id), do: :file_id

  @doc "Converts a part into a complete map for an adapter."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = part) do
    part
    |> Map.from_struct()
    |> Enum.reject(fn
      {_key, nil} -> true
      {:metadata, metadata} when metadata == %{} -> true
      {_key, _value} -> false
    end)
    |> Map.new()
  end

  @doc "Returns a safe public projection without media bytes or references."
  @spec project(t()) :: map()
  def project(%__MODULE__{type: :text} = part) do
    %{type: :text, text: part.text, metadata: Portable.project(part.metadata)}
    |> drop_empty_metadata()
  end

  def project(%__MODULE__{} = part) do
    %{
      type: part.type,
      source: source_kind(part),
      media_type: part.media_type,
      filename: part.filename,
      byte_size: data_size(part.data),
      metadata: Portable.project(part.metadata)
    }
    |> Enum.reject(fn
      {_key, nil} -> true
      {:metadata, metadata} when metadata == %{} -> true
      {_key, _value} -> false
    end)
    |> Map.new()
  end

  defp media!(type, source, opts) when type in @media_types and is_list(opts) do
    source_attrs = source_attrs!(source)

    new!(
      source_attrs ++
        [
          type: type,
          media_type: Keyword.get(opts, :media_type, Map.fetch!(@default_media_types, type)),
          filename: Keyword.get(opts, :filename),
          metadata: Keyword.get(opts, :metadata, %{})
        ]
    )
  end

  defp source_attrs!({:url, url}) when is_binary(url), do: [url: url]
  defp source_attrs!({:data, data}) when is_binary(data), do: [data: data]
  defp source_attrs!({:file_id, file_id}) when is_binary(file_id), do: [file_id: file_id]

  defp source_attrs!(source),
    do: raise(ArgumentError, "invalid content part source: #{inspect(source)}")

  defp validate(%__MODULE__{type: :text, text: text} = part) do
    cond do
      not is_binary(text) or String.trim(text) == "" ->
        {:error, :empty_text_content_part}

      source_count(part) > 0 ->
        {:error, {:text_content_part_has_media_source, source_kind(part)}}

      not is_nil(part.media_type) or not is_nil(part.filename) ->
        {:error, :text_content_part_has_media_fields}

      true ->
        :ok
    end
  end

  defp validate(%__MODULE__{type: type} = part) when type in @media_types do
    cond do
      source_count(part) != 1 ->
        {:error, {:invalid_content_part_source_count, type, source_count(part)}}

      not valid_source?(part) ->
        {:error, {:invalid_content_part_source, type}}

      not non_empty_string?(part.media_type) ->
        {:error, {:missing_media_type, type}}

      not is_nil(part.filename) and not non_empty_string?(part.filename) ->
        {:error, {:invalid_content_part_filename, type}}

      true ->
        :ok
    end
  end

  defp source_count(part) do
    Enum.count([part.url, part.data, part.file_id], &(not is_nil(&1)))
  end

  defp valid_source?(%__MODULE__{url: url}) when not is_nil(url), do: non_empty_string?(url)
  defp valid_source?(%__MODULE__{data: data}) when not is_nil(data), do: is_binary(data) and byte_size(data) > 0
  defp valid_source?(%__MODULE__{file_id: file_id}) when not is_nil(file_id), do: non_empty_string?(file_id)

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp put_default_media_type(%{} = attrs) do
    type = Schema.get_key(attrs, :type)
    type = if is_binary(type), do: Enum.find(@types, &(Atom.to_string(&1) == type)), else: type

    if type in @media_types and is_nil(Schema.get_key(attrs, :media_type)) do
      Map.put(attrs, :media_type, Map.fetch!(@default_media_types, type))
    else
      attrs
    end
  end

  defp put_default_media_type(attrs), do: attrs

  defp data_size(data) when is_binary(data), do: byte_size(data)
  defp data_size(_data), do: nil

  defp drop_empty_metadata(%{metadata: metadata} = map) when metadata == %{},
    do: Map.delete(map, :metadata)

  defp drop_empty_metadata(map), do: map
end
