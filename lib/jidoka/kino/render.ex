defmodule Jidoka.Kino.Render do
  @moduledoc false

  @doc false
  @spec value(term()) :: :ok
  def value(value) do
    if Code.ensure_loaded?(Kino) and function_exported?(Kino, :render, 1) do
      apply(Kino, :render, [value])
    else
      :ok
    end
  end

  @doc false
  @spec markdown(String.t()) :: :ok
  def markdown(markdown) when is_binary(markdown) do
    value =
      if Code.ensure_loaded?(Kino.Markdown) and function_exported?(Kino.Markdown, :new, 1) do
        apply(Kino.Markdown, :new, [markdown])
      else
        markdown
      end

    value(value)
  end

  @doc false
  @spec table(String.t(), [map()], keyword()) :: :ok
  def table(label, rows, opts \\ []) when is_binary(label) and is_list(rows) do
    keys = Keyword.get(opts, :keys, infer_keys(rows))

    label
    |> markdown_table(rows, keys)
    |> markdown()
  end

  @doc false
  @spec inspect_value(term(), non_neg_integer() | :infinity) :: String.t()
  def inspect_value(value, limit \\ 18), do: inspect(value, pretty: false, limit: limit)

  @doc false
  @spec format_module(module() | term()) :: String.t() | nil
  def format_module(nil), do: nil
  def format_module(module) when is_atom(module), do: inspect(module)
  def format_module(other), do: inspect_value(other)

  @doc false
  @spec format_list(term()) :: String.t()
  def format_list([]), do: "-"
  def format_list(values) when is_list(values), do: Enum.map_join(values, ", ", &to_string/1)
  def format_list(value), do: inspect_value(value)

  @doc false
  @spec reject_blank_rows([map()]) :: [map()]
  def reject_blank_rows(rows) do
    Enum.reject(rows, fn row -> blank?(Map.get(row, :value)) end)
  end

  @doc false
  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?("-"), do: true
  def blank?([]), do: true
  def blank?(_value), do: false

  @doc false
  @spec mermaid_label([term()]) :: String.t()
  def mermaid_label(parts) do
    parts
    |> Enum.reject(&blank?/1)
    |> Enum.map_join("\\n", fn part -> part |> to_string() |> mermaid_label_part() end)
  end

  @doc false
  @spec escape_markdown(String.t()) :: String.t()
  def escape_markdown(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("#", "\\#")
  end

  @doc false
  @spec compact(String.t()) :: String.t()
  def compact(message) do
    message
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc false
  @spec preview(term(), pos_integer()) :: String.t()
  def preview(value, max_length \\ 240)
  def preview(nil, _max_length), do: ""
  def preview(value, max_length) when is_binary(value), do: value |> compact() |> shorten(max_length)
  def preview(value, max_length), do: value |> inspect_value(20) |> compact() |> shorten(max_length)

  @doc false
  @spec shorten(String.t(), pos_integer()) :: String.t()
  def shorten(message, max_length) when is_integer(max_length) and max_length > 0 do
    if String.length(message) <= max_length do
      message
    else
      String.slice(message, 0, max_length - 1) <> "..."
    end
  end

  defp infer_keys([]), do: []

  defp infer_keys([%{} = row | _rows]) do
    row
    |> Map.keys()
    |> Enum.sort()
  end

  defp markdown_table(label, _rows, []), do: "### #{escape_markdown(label)}\n\n_No rows._"

  defp markdown_table(label, rows, keys) do
    headers = Enum.map_join(keys, " | ", &header/1)

    separator = Enum.map_join(keys, " | ", fn _key -> "---" end)

    body =
      Enum.map_join(rows, "\n", fn row ->
        cells =
          Enum.map_join(keys, " | ", fn key ->
            row |> Map.get(key, "") |> table_cell()
          end)

        "| #{cells} |"
      end)

    "### #{escape_markdown(label)}\n\n| #{headers} |\n| #{separator} |\n#{body}"
  end

  defp header(key) do
    key
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
    |> escape_table_cell()
  end

  defp table_cell(value) when is_binary(value), do: escape_table_cell(value)
  defp table_cell(value), do: value |> inspect() |> escape_table_cell()

  defp escape_table_cell(value) do
    value
    |> compact()
    |> shorten(220)
    |> String.replace("\\", "\\\\")
    |> String.replace("|", "\\|")
  end

  defp mermaid_label_part(part) do
    part
    |> String.replace("\\", "/")
    |> String.replace("\"", "'")
    |> String.replace("[", "(")
    |> String.replace("]", ")")
  end
end
