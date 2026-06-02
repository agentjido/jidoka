defmodule Jidoka.Workflow.Dsl.Error do
  @moduledoc false

  @spec exception(keyword()) :: Spark.Error.DslError.t()
  def exception(opts) when is_list(opts) do
    Spark.Error.DslError.exception(
      message:
        format_message(
          Keyword.fetch!(opts, :message),
          Keyword.get(opts, :path),
          Keyword.get(opts, :value, :__jidoka_no_value__),
          Keyword.get(opts, :hint)
        ),
      path: Keyword.get(opts, :path),
      module: Keyword.get(opts, :module),
      location: Keyword.get(opts, :location)
    )
  end

  defp format_message(message, path, value, hint) do
    [message, path_line(path), value_line(value), hint_line(hint)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp path_line(nil), do: nil
  defp path_line(path), do: "Section path: #{format_path(path)}"

  defp value_line(:__jidoka_no_value__), do: nil
  defp value_line(value), do: "Invalid value: #{inspect(value)}"

  defp hint_line(nil), do: nil
  defp hint_line(hint), do: "Fix: #{hint}"

  defp format_path(path) when is_list(path) do
    Enum.map_join(path, ".", &to_string/1)
  end

  defp format_path(path), do: to_string(path)
end
