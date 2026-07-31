defmodule Jidoka.CheckLivebook do
  @moduledoc false

  @cell_key {__MODULE__, :current_cell}

  def run(args) do
    args = if List.first(args) == "--", do: tl(args), else: args
    {opts, positional, invalid} = OptionParser.parse(args, strict: [project: :boolean])

    if invalid != [] or length(positional) != 1 do
      raise "Usage: elixir examples/_support/check_livebook.exs [--project] PATH; got #{inspect(args)}"
    end

    path = positional |> List.first() |> Path.expand()
    cells = read_cells!(path)
    quoted = quoted_cells!(cells, path, opts[:project])

    try do
      Code.eval_quoted(quoted, [], file: path)
    rescue
      exception ->
        {cell, line} = failure_location(exception, cells)

        raise RuntimeError,
              "Livebook cell #{cell} at #{path}:#{line} failed: #{Exception.message(exception)}"
    after
      Process.delete(@cell_key)
    end

    IO.puts("PASS #{path} (#{length(cells)} code cells)")
  end

  defp read_cells!(path) do
    content = File.read!(path)

    cells =
      ~r/```elixir\s*\n(.*?)```/s
      |> Regex.scan(content, return: :index, capture: :all_but_first)
      |> Enum.with_index(1)
      |> Enum.map(fn {[{start, length}], index} ->
        line = content |> binary_part(0, start) |> count_lines()
        %{index: index, line: line, source: binary_part(content, start, length)}
      end)

    if cells == [], do: raise("No Elixir cells found in #{path}"), else: cells
  end

  defp quoted_cells!(cells, path, project?) do
    expressions =
      Enum.flat_map(cells, fn cell ->
        quoted = parse_cell!(cell, path) |> maybe_remove_mix_install(project?)

        [marker(cell) | block_expressions(quoted)]
      end)

    {:__block__, [], expressions}
  end

  defp parse_cell!(cell, path) do
    Code.string_to_quoted!(cell.source, file: path, line: cell.line)
  rescue
    exception ->
      raise RuntimeError,
            "Livebook cell #{cell.index} at #{path}:#{cell.line} failed: #{Exception.message(exception)}"
  end

  defp marker(cell) do
    quote do
      Process.put(unquote(@cell_key), {unquote(cell.index), unquote(cell.line)})
    end
  end

  defp block_expressions({:__block__, _metadata, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp maybe_remove_mix_install(quoted, true), do: remove_mix_install(quoted)
  defp maybe_remove_mix_install(quoted, _project?), do: quoted

  defp remove_mix_install({:__block__, metadata, expressions}) do
    {:__block__, metadata, Enum.reject(expressions, &mix_install?/1)}
  end

  defp remove_mix_install(expression) do
    if mix_install?(expression), do: {:__block__, [], []}, else: expression
  end

  defp mix_install?({{:., _, [{:__aliases__, _, [:Mix]}, :install]}, _, _}), do: true
  defp mix_install?(_expression), do: false

  defp count_lines(content), do: length(String.split(content, "\n"))

  defp failure_location(exception, cells) do
    case Process.get(@cell_key) do
      nil -> location_from_exception(exception, cells)
      location -> location
    end
  end

  defp location_from_exception(exception, cells) do
    line = if is_map(exception), do: Map.get(exception, :line), else: nil

    case Enum.find(cells, fn cell ->
           is_integer(line) and line >= cell.line and
             line < cell.line + count_lines(cell.source)
         end) do
      nil -> {:unknown, line || :unknown}
      cell -> {cell.index, line}
    end
  end
end

Jidoka.CheckLivebook.run(System.argv())
