case System.argv() do
  [path] ->
    path = Path.expand(path)
    markdown = File.read!(path)

    cells =
      ~r/```elixir\n(.*?)```/s
      |> Regex.scan(markdown, capture: :all_but_first)
      |> Enum.map(&List.first/1)

    if cells == [] do
      raise "No Elixir cells found in #{path}"
    end

    cells
    |> Enum.join("\n\n")
    |> Code.eval_string([], file: path)

    IO.puts("PASS #{path} (#{length(cells)} cells)")

  _args ->
    raise "Usage: elixir scripts/check_livebook.exs PATH"
end
