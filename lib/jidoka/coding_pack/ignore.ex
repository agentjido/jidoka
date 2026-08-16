defmodule Jidoka.CodingPack.Ignore do
  @moduledoc "Deterministic, explainable workspace ignore evaluation."

  alias Jidoka.CodingPack.{Error, Workspace}

  @default_exclusions [
    ".git",
    ".git/**",
    ".env",
    ".env.*",
    "**/.env",
    "**/.env.*",
    "**/*.pem",
    "**/*.key",
    "deps",
    "deps/**",
    "_build",
    "_build/**",
    "node_modules",
    "node_modules/**"
  ]

  @type decision :: %{
          ignored?: boolean(),
          path: String.t(),
          pattern: String.t() | nil,
          source: String.t() | nil,
          kind: String.t()
        }

  defmodule Evaluator do
    @moduledoc false
    @enforce_keys [:workspace, :hard_rules, :rules]
    defstruct [:workspace, :hard_rules, :rules]

    @type t :: %__MODULE__{workspace: Workspace.t(), hard_rules: [map()], rules: [map()]}
  end

  @doc "Returns the non-overridable default exclusions."
  @spec default_exclusions() :: [String.t()]
  def default_exclusions, do: @default_exclusions

  @doc "Explains whether a workspace path is ignored."
  @spec decision(Workspace.t(), String.t()) :: {:ok, decision()} | {:error, Error.t()}
  def decision(%Workspace{} = workspace, path) do
    with {:ok, resolved} <- Workspace.resolve(workspace, path, allow_missing: true),
         :ok <- valid_patterns(workspace.trusted_exclusions),
         hard_rules = compile_hard_rules(@default_exclusions ++ workspace.trusted_exclusions),
         nil <- first_match(hard_rules, resolved.relative),
         {:ok, rules} <- load_rules(workspace, resolved.relative, resolved.type) do
      {:ok, apply_rules(rules, resolved.relative)}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:ignore_rules_invalid, %{reason: inspect(reason)})}

      pattern when is_binary(pattern) ->
        {:ok,
         %{
           ignored?: true,
           path: normalize(path),
           pattern: pattern,
           source: "trusted",
           kind: "trusted_exclusion"
         }}
    end
  end

  def decision(%Evaluator{} = evaluator, path) do
    with {:ok, resolved} <- Workspace.resolve(evaluator.workspace, path, allow_missing: true),
         nil <- first_match(evaluator.hard_rules, resolved.relative) do
      {:ok, apply_rules(evaluator.rules, resolved.relative)}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      pattern when is_binary(pattern) ->
        {:ok,
         %{
           ignored?: true,
           path: normalize(path),
           pattern: pattern,
           source: "trusted",
           kind: "trusted_exclusion"
         }}
    end
  end

  @doc "Builds one immutable ignore evaluator for a bounded workspace search."
  @spec compile(Workspace.t(), keyword()) :: {:ok, Evaluator.t()} | {:error, Error.t()}
  def compile(%Workspace{} = workspace, opts \\ []) do
    with :ok <- valid_patterns(workspace.trusted_exclusions),
         hard_rules = compile_hard_rules(@default_exclusions ++ workspace.trusted_exclusions),
         {:ok, directories, _visited} <- collect_directories(workspace, hard_rules, opts),
         {:ok, rules} <- load_directory_rules(workspace, directories, opts) do
      {:ok, %Evaluator{workspace: workspace, hard_rules: hard_rules, rules: rules}}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:ignore_rules_invalid, %{reason: inspect(reason)})}
    end
  end

  @doc "Returns true only after a successful ignore decision."
  @spec ignored?(Workspace.t(), String.t()) :: {:ok, boolean()} | {:error, Error.t()}
  def ignored?(%Workspace{} = workspace, path) do
    with {:ok, result} <- decision(workspace, path), do: {:ok, result.ignored?}
  end

  defp load_rules(workspace, relative, type) do
    relative
    |> ancestor_dirs(type)
    |> Enum.reduce_while({:ok, []}, fn directory, {:ok, rules} ->
      case rules_in_directory(workspace, directory, []) do
        {:ok, next} -> {:cont, {:ok, rules ++ next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rules_in_directory(workspace, directory, opts) do
    Enum.reduce_while(workspace.ignore_files, {:ok, []}, fn filename, {:ok, rules} ->
      path = join_relative(directory, filename)
      ignore_file_step(workspace, directory, path, rules, opts)
    end)
  end

  defp ignore_file_step(workspace, directory, path, rules, opts) do
    case Workspace.resolve(workspace, path, type: :regular) do
      {:ok, resolved} -> append_rules(read_rules(resolved.absolute, path, directory, opts), rules)
      {:error, %Error{details: %{reason: reason}}} -> unavailable_rule_step(path, reason, rules)
    end
  end

  defp append_rules({:ok, next}, rules), do: {:cont, {:ok, rules ++ next}}
  defp append_rules({:error, reason}, _rules), do: {:halt, {:error, reason}}

  defp unavailable_rule_step(path, reason, rules) do
    if String.contains?(reason, ":enoent"),
      do: {:cont, {:ok, rules}},
      else: {:halt, {:error, {:ignore_file_unavailable, path, reason}}}
  end

  defp read_rules(absolute, source, directory, opts) do
    with {:ok, stat} <- rule_stat(opts).(absolute),
         true <- stat.size <= 262_144,
         {:ok, contents} <- rule_read_file(opts).(absolute),
         true <- String.valid?(contents) do
      parse_lines(contents, source, directory)
    else
      false -> {:error, {:ignore_file_too_large, source}}
      {:error, reason} -> {:error, {:ignore_file_unavailable, source, reason}}
    end
  end

  defp parse_lines(contents, source, directory) do
    contents
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, number}, accumulator ->
      parse_line_step(parse_rule(line, source, directory, number), accumulator)
    end)
  end

  defp parse_line_step(:skip, {:ok, rules}), do: {:cont, {:ok, rules}}
  defp parse_line_step({:ok, rule}, {:ok, rules}), do: {:cont, {:ok, rules ++ [rule]}}
  defp parse_line_step({:error, reason}, _accumulator), do: {:halt, {:error, reason}}

  defp parse_rule(line, source, directory, number) do
    line = String.trim_trailing(line, "\r")

    cond do
      line == "" or String.starts_with?(line, "#") ->
        :skip

      not String.valid?(line) or String.contains?(line, <<0>>) ->
        {:error, {:invalid_ignore_pattern, source, number}}

      String.contains?(line, ["[", "]"]) ->
        {:error, {:unsupported_ignore_pattern, source, number, line}}

      true ->
        {negated?, line} = unprefix(line, "!", true)
        {_escaped?, line} = unprefix(line, "\\!", false)
        {_escaped_comment?, line} = unprefix(line, "\\#", false)
        directory_only? = String.ends_with?(line, "/")
        line = String.trim_trailing(line, "/")
        anchored? = String.starts_with?(line, "/")
        line = String.trim_leading(line, "/")

        if line == "" or Enum.any?(Path.split(line), &(&1 == "..")) do
          {:error, {:invalid_ignore_pattern, source, number, line}}
        else
          rule = %{
            pattern: line,
            negated?: negated?,
            directory_only?: directory_only?,
            anchored?: anchored?,
            source: source,
            directory: directory
          }

          {:ok, Map.put(rule, :regex, rule_regex(rule))}
        end
    end
  end

  defp apply_rules(rules, relative) do
    initial = %{ignored?: false, path: relative, pattern: nil, source: nil, kind: "included"}

    Enum.reduce(rules, initial, fn rule, decision ->
      if rule_match?(rule, relative) do
        %{
          ignored?: not rule.negated?,
          path: relative,
          pattern: if(rule.negated?, do: "!" <> rule.pattern, else: rule.pattern),
          source: rule.source,
          kind: if(rule.negated?, do: "ignore_negation", else: "ignore_file")
        }
      else
        decision
      end
    end)
  end

  defp rule_match?(rule, relative) do
    case relative_from(rule.directory, relative) do
      nil -> false
      local -> Regex.match?(Map.get(rule, :regex) || rule_regex(rule), local)
    end
  end

  defp rule_regex(rule) do
    body = glob_regex(rule.pattern)
    contains_slash? = String.contains?(rule.pattern, "/") or rule.anchored?

    expression =
      cond do
        contains_slash? and rule.directory_only? -> "^#{body}(?:/.*)?$"
        contains_slash? -> "^#{body}$"
        rule.directory_only? -> "(?:^|/)#{body}(?:/.*)?$"
        true -> "(?:^|/)#{body}$"
      end

    Regex.compile!(expression)
  end

  defp glob_regex(pattern) do
    pattern
    |> String.graphemes()
    |> glob_parts([])
    |> Enum.reverse()
    |> Enum.join()
  end

  defp glob_parts([], acc), do: acc
  defp glob_parts(["*", "*" | rest], acc), do: glob_parts(rest, [".*" | acc])
  defp glob_parts(["*" | rest], acc), do: glob_parts(rest, ["[^/]*" | acc])
  defp glob_parts(["?" | rest], acc), do: glob_parts(rest, ["[^/]" | acc])
  defp glob_parts([character | rest], acc), do: glob_parts(rest, [Regex.escape(character) | acc])

  defp first_match(rules, relative) do
    case Enum.find(rules, &Regex.match?(&1.regex, relative)) do
      nil -> nil
      rule -> rule.original_pattern
    end
  end

  defp compile_hard_rules(patterns) do
    Enum.map(patterns, fn pattern ->
      rule = %{
        pattern: String.trim_trailing(pattern, "/"),
        directory_only?: String.ends_with?(pattern, "/"),
        anchored?: false
      }

      Map.merge(rule, %{original_pattern: pattern, regex: rule_regex(rule)})
    end)
  end

  defp collect_directories(workspace, hard_rules, opts) do
    collect_directory(workspace, ".", hard_rules, ["."], 0, opts)
  end

  defp collect_directory(workspace, directory, hard_rules, directories, visited, opts) do
    absolute = if directory == ".", do: workspace.root, else: Path.join(workspace.root, directory)

    case ignore_list_dir(opts).(absolute) do
      {:ok, names} ->
        Enum.reduce_while(Enum.sort(names), {:ok, directories, visited}, fn name, {:ok, directories, visited} ->
          relative = join_relative(directory, name)
          visited = visited + 1

          cond do
            visited > workspace.limits.max_search_files ->
              {:halt,
               {:error,
                Error.new(:coding_search_file_limit_exceeded, %{
                  limit: workspace.limits.max_search_files
                })}}

            first_match(hard_rules, relative) != nil ->
              {:cont, {:ok, directories, visited}}

            true ->
              case ignore_lstat(opts).(Path.join(workspace.root, relative)) do
                {:ok, %{type: :directory}} ->
                  case collect_directory(
                         workspace,
                         relative,
                         hard_rules,
                         directories ++ [relative],
                         visited,
                         opts
                       ) do
                    {:ok, next_directories, next_visited} ->
                      {:cont, {:ok, next_directories, next_visited}}

                    {:error, reason} ->
                      {:halt, {:error, reason}}
                  end

                {:ok, _stat} ->
                  {:cont, {:ok, directories, visited}}

                {:error, reason} ->
                  {:halt,
                   {:error,
                    Error.new(:coding_search_io_error, %{
                      path: relative,
                      reason: inspect(reason)
                    })}}
              end
          end
        end)

      {:error, reason} ->
        {:error, Error.new(:coding_search_io_error, %{path: directory, reason: inspect(reason)})}
    end
  end

  defp load_directory_rules(workspace, directories, opts) do
    Enum.reduce_while(directories, {:ok, []}, fn directory, {:ok, rules} ->
      case rules_in_directory(workspace, directory, opts) do
        {:ok, next} -> {:cont, {:ok, rules ++ next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp valid_patterns(patterns) do
    if Enum.all?(patterns, &(not String.contains?(&1, ["[", "]", <<0>>]))),
      do: :ok,
      else: {:error, :invalid_trusted_exclusion}
  end

  defp ancestor_dirs(relative, type) do
    parts = if relative == ".", do: [], else: Path.split(relative)
    directory_parts = if type == :directory, do: parts, else: Enum.drop(parts, -1)

    Enum.reduce(directory_parts, ["."], fn part, acc ->
      previous = List.last(acc)
      acc ++ [join_relative(previous, part)]
    end)
  end

  defp relative_from(".", relative), do: relative
  defp relative_from(directory, directory), do: "."

  defp relative_from(directory, relative) do
    prefix = directory <> "/"
    if String.starts_with?(relative, prefix), do: String.replace_prefix(relative, prefix, ""), else: nil
  end

  defp join_relative(".", path), do: normalize(path)
  defp join_relative(directory, path), do: normalize(Path.join(directory, path))
  defp normalize(path), do: String.replace(path, "\\", "/")

  defp unprefix(value, prefix, flag) do
    if String.starts_with?(value, prefix), do: {flag, String.replace_prefix(value, prefix, "")}, else: {false, value}
  end

  defp ignore_list_dir(opts), do: Keyword.get(opts, :ignore_list_dir, &File.ls/1)
  defp ignore_lstat(opts), do: Keyword.get(opts, :ignore_lstat, &File.lstat/1)
  defp rule_stat(opts), do: Keyword.get(opts, :ignore_rule_stat, &File.stat/1)
  defp rule_read_file(opts), do: Keyword.get(opts, :ignore_rule_read_file, &File.read/1)
end
