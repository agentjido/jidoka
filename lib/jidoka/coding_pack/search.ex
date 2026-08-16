defmodule Jidoka.CodingPack.Search do
  @moduledoc "Deterministic bounded path and literal-text search for a coding workspace."

  alias Jidoka.CodingPack.{Error, Glob, Ignore, Workspace}

  @keys ~w(mode path pattern glob case_sensitive max_results max_bytes)

  @doc "Returns the model-visible search operation and its local handler."
  @spec tool(Workspace.t()) :: %{operation: Jidoka.Agent.Spec.Operation.t(), handler: function()}
  def tool(%Workspace{} = workspace) do
    %{
      operation:
        Jidoka.Agent.Spec.Operation.new!(
          name: "coding.search",
          description: "Search workspace paths or UTF-8 text with stable bounded results.",
          idempotency: :pure,
          metadata: %{
            "kind" => "tool",
            "source" => "coding_pack",
            "parameters_schema" => input_schema(workspace),
            "policy_resource" => %{
              "kind" => "coding_workspace",
              "access" => "read",
              "argument_fields" => ["mode", "path", "pattern", "glob"]
            }
          }
        ),
      handler: fn arguments, _context -> run(workspace, arguments) end
    }
  end

  defp input_schema(workspace) do
    %{
      "type" => "object",
      "properties" => %{
        "mode" => %{"type" => "string", "enum" => ["path", "text"]},
        "path" => %{"type" => "string", "minLength" => 1},
        "pattern" => %{"type" => "string", "minLength" => 1},
        "glob" => %{"type" => "string"},
        "case_sensitive" => %{"type" => "boolean"},
        "max_results" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => workspace.limits.max_search_results
        },
        "max_bytes" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => workspace.limits.max_result_bytes
        }
      },
      "required" => ["pattern"],
      "additionalProperties" => false
    }
  end

  @doc "Runs a bounded path or literal-text search without a shell fallback."
  @spec run(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(workspace, arguments, opts \\ [])

  def run(%Workspace{} = workspace, arguments, opts) when is_map(arguments) do
    with :ok <- read_access(workspace),
         {:ok, input} <- input(arguments, workspace),
         {:ok, base} <- resolve_base(workspace, input.path),
         {:ok, ignore} <- Ignore.compile(workspace, opts),
         {:ok, base_ignore} <- base_ignore(ignore, base.relative),
         :ok <- included(base_ignore),
         {:ok, entries, facts} <- enumerate(workspace, ignore, base.relative, opts),
         {:ok, result} <- search(Map.put(input, :base, base.relative), entries, facts, workspace, opts) do
      {:ok, result}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def run(%Workspace{}, _arguments, _opts), do: {:error, Error.new(:coding_search_input_invalid)}

  defp input(arguments, workspace) do
    arguments = stringify_keys(arguments)
    unknown = Map.keys(arguments) -- @keys
    mode = Map.get(arguments, "mode", "text")
    path = Map.get(arguments, "path", ".")
    pattern = Map.get(arguments, "pattern")
    glob = Map.get(arguments, "glob", if(mode == "path", do: pattern, else: "**/*"))

    with [] <- unknown,
         true <- mode in ["path", "text"],
         true <- is_binary(path) and path != "",
         true <- is_binary(pattern) and pattern != "" and String.valid?(pattern),
         {:ok, glob_regex} <- Glob.compile(glob),
         {:ok, max_results} <- ceiling(Map.get(arguments, "max_results"), workspace.limits.max_search_results),
         {:ok, max_bytes} <- ceiling(Map.get(arguments, "max_bytes"), workspace.limits.max_result_bytes),
         case_sensitive when is_boolean(case_sensitive) <- Map.get(arguments, "case_sensitive", true) do
      {:ok,
       %{
         mode: mode,
         path: path,
         pattern: pattern,
         glob: glob,
         glob_regex: glob_regex,
         max_results: max_results,
         max_bytes: max_bytes,
         case_sensitive: case_sensitive
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      reason -> {:error, Error.new(:coding_search_input_invalid, %{reason: inspect(reason)})}
    end
  end

  defp enumerate(workspace, ignore, base, opts) do
    state = %{entries: [], visited: 0, ignored: 0, binary: 0, oversized: 0}

    case walk_directory(workspace, ignore, base, state, opts) do
      {:ok, state} -> {:ok, Enum.sort_by(state.entries, & &1.relative), Map.delete(state, :entries)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp walk_directory(workspace, ignore, directory, state, opts) do
    absolute = absolute(workspace, directory)

    case list_dir(opts).(absolute) do
      {:ok, names} -> walk_names(workspace, ignore, directory, Enum.sort(names), state, opts)
      {:error, reason} -> {:error, Error.new(:coding_search_io_error, %{path: directory, reason: inspect(reason)})}
    end
  end

  defp walk_names(_workspace, _ignore, _directory, [], state, _opts), do: {:ok, state}

  defp walk_names(workspace, ignore, directory, [name | rest], state, opts) do
    relative = join(directory, name)
    visited = state.visited + 1

    if visited > workspace.limits.max_search_files do
      {:error, Error.new(:coding_search_file_limit_exceeded, %{limit: workspace.limits.max_search_files})}
    else
      state = %{state | visited: visited}

      case entry(workspace, ignore, relative, state, opts) do
        {:ok, state} -> walk_names(workspace, ignore, directory, rest, state, opts)
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  defp entry(workspace, evaluator, relative, state, opts) do
    with {:ok, decision} <- Ignore.decision(evaluator, relative) do
      if decision.ignored? do
        {:ok, %{state | ignored: state.ignored + 1}}
      else
        include_entry(workspace, evaluator, relative, state, opts)
      end
    end
  end

  defp include_entry(workspace, ignore, relative, state, opts) do
    path = absolute(workspace, relative)

    case lstat(opts).(path) do
      {:ok, %{type: :directory}} ->
        state = %{state | entries: [%{relative: relative, type: :directory, absolute: path} | state.entries]}
        walk_directory(workspace, ignore, relative, state, opts)

      {:ok, %{type: :regular}} ->
        {:ok, %{state | entries: [%{relative: relative, type: :regular, absolute: path} | state.entries]}}

      {:ok, %{type: :symlink}} ->
        include_symlink(workspace, relative, state)

      {:ok, _stat} ->
        {:ok, state}

      {:error, reason} ->
        {:error, Error.new(:coding_search_io_error, %{path: relative, reason: inspect(reason)})}
    end
  end

  defp include_symlink(workspace, relative, state) do
    case Workspace.resolve(workspace, relative) do
      {:ok, %{type: :regular} = resolved} ->
        entry = %{relative: resolved.relative, type: :regular, absolute: resolved.absolute}
        {:ok, %{state | entries: [entry | state.entries]}}

      {:ok, %{type: :directory}} ->
        {:ok, state}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp search(%{mode: "path"} = input, entries, facts, _workspace, _opts) do
    collector =
      entries
      |> Enum.filter(&Regex.match?(input.glob_regex, local_path(input.base, &1.relative)))
      |> Enum.map(&%{"path" => &1.relative, "type" => Atom.to_string(&1.type)})
      |> Enum.reduce(new_collector(input), &collect_match(&2, &1))

    {:ok, result(input, collector, facts)}
  end

  defp search(%{mode: "text"} = input, entries, facts, workspace, opts) do
    input = Map.put(input, :text_regex, text_regex(input))

    entries
    |> Enum.filter(&(&1.type == :regular and Regex.match?(input.glob_regex, local_path(input.base, &1.relative))))
    |> Enum.reduce_while({:ok, new_collector(input), facts}, fn entry, {:ok, collector, facts} ->
      case text_matches(entry, input, workspace, collector, opts) do
        {:ok, :binary} -> {:cont, {:ok, collector, %{facts | binary: facts.binary + 1}}}
        {:ok, :oversized} -> {:cont, {:ok, collector, %{facts | oversized: facts.oversized + 1}}}
        {:ok, collector} -> {:cont, {:ok, collector, facts}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, collector, facts} -> {:ok, result(input, collector, facts)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp text_matches(entry, input, workspace, collector, opts) do
    with {:ok, before_stat} <- stat(opts).(entry.absolute),
         :ok <- searchable_size(before_stat.size, workspace.limits.max_file_bytes),
         {:ok, contents} <- read_file(opts).(entry.absolute),
         {:ok, after_stat} <- stat(opts).(entry.absolute),
         :ok <- unchanged(before_stat, after_stat) do
      if String.valid?(contents) and not String.contains?(contents, <<0>>) do
        {:ok, collect_line_matches(entry.relative, contents, input, collector)}
      else
        {:ok, :binary}
      end
    else
      {:error, :oversized} -> {:ok, :oversized}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:coding_search_io_error, %{path: entry.relative, reason: inspect(reason)})}
    end
  end

  defp collect_line_matches(path, contents, input, collector) do
    digest = digest(contents)

    contents
    |> String.splitter("\n", trim: false)
    |> Stream.with_index(1)
    |> Enum.reduce(collector, fn {line, number}, collector ->
      input.text_regex
      |> Regex.scan(line, return: :index)
      |> Enum.reduce(collector, fn [{offset, _length}], collector ->
        collect_match(collector, %{
          "path" => path,
          "line" => number,
          "column" => column(line, offset),
          "preview" => preview(line),
          "file_sha256" => digest
        })
      end)
    end)
  end

  defp result(input, collector, facts) do
    returned = Enum.reverse(collector.matches)

    %{
      "mode" => input.mode,
      "path" => input.path,
      "pattern" => input.pattern,
      "glob" => input.glob,
      "matches" => returned,
      "total_count" => collector.total_count,
      "returned_count" => collector.returned_count,
      "output_bytes" => collector.output_bytes,
      "truncated" => collector.returned_count < collector.total_count,
      "scanned_entries" => facts.visited,
      "ignored_entries" => facts.ignored,
      "binary_files" => facts.binary,
      "oversized_files" => facts.oversized
    }
  end

  defp new_collector(input) do
    %{
      matches: [],
      total_count: 0,
      returned_count: 0,
      output_bytes: 0,
      max_results: input.max_results,
      max_bytes: input.max_bytes,
      closed?: false
    }
  end

  defp collect_match(%{closed?: true} = collector, _match),
    do: %{collector | total_count: collector.total_count + 1}

  defp collect_match(collector, match) do
    total_count = collector.total_count + 1

    if collector.returned_count >= collector.max_results do
      %{collector | total_count: total_count, closed?: true}
    else
      size = match |> Jason.encode!() |> byte_size()

      if collector.output_bytes + size <= collector.max_bytes do
        %{
          collector
          | matches: [match | collector.matches],
            total_count: total_count,
            returned_count: collector.returned_count + 1,
            output_bytes: collector.output_bytes + size
        }
      else
        %{collector | total_count: total_count, closed?: true}
      end
    end
  end

  defp text_regex(input) do
    options = if input.case_sensitive, do: "u", else: "iu"
    Regex.compile!(Regex.escape(input.pattern), options)
  end

  defp column(line, offset), do: line |> binary_part(0, offset) |> String.length() |> Kernel.+(1)
  defp preview(line), do: if(byte_size(line) <= 512, do: line, else: utf8_prefix(line, 512) <> "…")

  defp utf8_prefix(contents, max_bytes) do
    candidate = binary_part(contents, 0, max_bytes)
    if String.valid?(candidate), do: candidate, else: utf8_prefix(contents, max_bytes - 1)
  end

  defp searchable_size(size, limit) when size <= limit, do: :ok
  defp searchable_size(_size, _limit), do: {:error, :oversized}

  defp unchanged(before_stat, after_stat) do
    if before_stat.size == after_stat.size and before_stat.mtime == after_stat.mtime,
      do: :ok,
      else: {:error, Error.new(:coding_file_changed_during_search)}
  end

  defp read_access(workspace) do
    if Workspace.permits?(workspace, :read),
      do: :ok,
      else: {:error, Error.new(:coding_search_denied, %{reason: :workspace_access})}
  end

  defp resolve_base(workspace, path) do
    case Workspace.resolve(workspace, path, type: :directory) do
      {:error, %Error{details: %{reason: reason}}} when is_binary(reason) ->
        if String.contains?(reason, ":enoent"),
          do: {:error, Error.new(:coding_search_path_not_found, %{path: path})},
          else: Workspace.resolve(workspace, path, type: :directory)

      result ->
        result
    end
  end

  defp included(%{ignored?: false}), do: :ok

  defp included(decision),
    do: {:error, Error.new(:coding_path_ignored, %{path: decision.path, pattern: decision.pattern})}

  defp base_ignore(_ignore, "."),
    do: {:ok, %{ignored?: false, path: ".", pattern: nil}}

  defp base_ignore(ignore, relative), do: Ignore.decision(ignore, relative)

  defp ceiling(nil, limit), do: {:ok, limit}
  defp ceiling(value, limit) when is_integer(value) and value > 0 and value <= limit, do: {:ok, value}
  defp ceiling(_value, _limit), do: {:error, :requested_limit_exceeds_workspace}

  defp absolute(workspace, "."), do: workspace.root
  defp absolute(workspace, relative), do: Path.join(workspace.root, relative)
  defp local_path(".", relative), do: relative
  defp local_path(base, relative), do: String.replace_prefix(relative, base <> "/", "")
  defp join(".", name), do: normalize(name)
  defp join(directory, name), do: Path.join(directory, name) |> normalize()
  defp normalize(path), do: String.replace(path, "\\", "/")
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp list_dir(opts), do: Keyword.get(opts, :list_dir, &File.ls/1)
  defp lstat(opts), do: Keyword.get(opts, :lstat, &File.lstat/1)
  defp stat(opts), do: Keyword.get(opts, :stat, &File.stat/1)
  defp read_file(opts), do: Keyword.get(opts, :read_file, &File.read/1)

  defp digest(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
end
