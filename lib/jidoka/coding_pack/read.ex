defmodule Jidoka.CodingPack.Read do
  @moduledoc "Bounded UTF-8 file reads through a trusted coding workspace."

  alias Jidoka.CodingPack.{Error, Ignore, Workspace}

  @keys ~w(path start_line end_line offset length max_bytes)

  @doc "Returns the model-visible read operation and its local handler."
  @spec tool(Workspace.t()) :: %{operation: Jidoka.Agent.Spec.Operation.t(), handler: function()}
  def tool(%Workspace{} = workspace) do
    %{
      operation:
        Jidoka.Agent.Spec.Operation.new!(
          name: "coding.read",
          description: "Read bounded UTF-8 text from one workspace file.",
          idempotency: :pure,
          metadata: %{
            "kind" => "tool",
            "source" => "coding_pack",
            "parameters_schema" => input_schema(workspace),
            "policy_resource" => %{
              "kind" => "coding_workspace",
              "access" => "read",
              "argument_fields" => ["path", "start_line", "end_line", "offset", "length"]
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
        "path" => %{"type" => "string", "minLength" => 1},
        "start_line" => %{"type" => "integer", "minimum" => 1},
        "end_line" => %{"type" => "integer", "minimum" => 1},
        "offset" => %{"type" => "integer", "minimum" => 0},
        "length" => %{"type" => "integer", "minimum" => 1},
        "max_bytes" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => workspace.limits.max_result_bytes
        }
      },
      "required" => ["path"],
      "additionalProperties" => false,
      "not" => %{
        "anyOf" => [
          %{"required" => ["start_line", "offset"]},
          %{"required" => ["start_line", "length"]},
          %{"required" => ["end_line", "offset"]},
          %{"required" => ["end_line", "length"]}
        ]
      }
    }
  end

  @doc "Reads one file with trusted size and output ceilings."
  @spec run(Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(workspace, arguments, opts \\ [])

  def run(%Workspace{} = workspace, arguments, opts) when is_map(arguments) do
    with :ok <- read_access(workspace),
         {:ok, input} <- input(arguments, workspace),
         {:ok, resolved} <- resolve_file(workspace, input.path),
         {:ok, ignore} <- Ignore.decision(workspace, resolved.relative),
         :ok <- included(ignore),
         {:ok, before_stat} <- file_stat(opts, resolved),
         :ok <- file_size(before_stat.size, workspace.limits.max_file_bytes),
         {:ok, contents} <- file_read(opts, resolved),
         :ok <- text(contents),
         {:ok, selected, range, range_truncated?} <- select(contents, input),
         {selected, cap_truncated?} <- cap(selected, input.max_bytes),
         {:ok, after_stat} <- file_stat(opts, resolved),
         :ok <- unchanged(before_stat, after_stat) do
      {:ok,
       %{
         "path" => resolved.relative,
         "content" => selected,
         "sha256" => digest(contents),
         "size" => before_stat.size,
         "range" => range,
         "truncated" => range_truncated? or cap_truncated?,
         "ignore" => ignore_projection(ignore)
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def run(%Workspace{}, _arguments, _opts), do: {:error, Error.new(:coding_read_input_invalid)}

  defp input(arguments, workspace) do
    arguments = stringify_keys(arguments)
    unknown = Map.keys(arguments) -- @keys
    path = Map.get(arguments, "path")

    with [] <- unknown,
         true <- is_binary(path) and path != "",
         {:ok, range} <- range(arguments),
         {:ok, max_bytes} <- ceiling(Map.get(arguments, "max_bytes"), workspace.limits.max_result_bytes) do
      {:ok, Map.merge(range, %{path: path, max_bytes: max_bytes})}
    else
      reason -> {:error, Error.new(:coding_read_input_invalid, %{reason: inspect(reason)})}
    end
  end

  defp range(arguments) do
    line? = Map.has_key?(arguments, "start_line") or Map.has_key?(arguments, "end_line")
    byte? = Map.has_key?(arguments, "offset") or Map.has_key?(arguments, "length")

    cond do
      line? and byte? -> {:error, :mixed_read_ranges}
      line? -> line_range(arguments)
      byte? -> byte_range(arguments)
      true -> {:ok, %{range_kind: :all}}
    end
  end

  defp line_range(arguments) do
    first = Map.get(arguments, "start_line", 1)
    last = Map.get(arguments, "end_line")

    if is_integer(first) and first > 0 and (is_nil(last) or (is_integer(last) and last >= first)),
      do: {:ok, %{range_kind: :lines, start_line: first, end_line: last}},
      else: {:error, :invalid_line_range}
  end

  defp byte_range(arguments) do
    offset = Map.get(arguments, "offset", 0)
    length = Map.get(arguments, "length")

    if is_integer(offset) and offset >= 0 and (is_nil(length) or (is_integer(length) and length > 0)),
      do: {:ok, %{range_kind: :bytes, offset: offset, length: length}},
      else: {:error, :invalid_byte_range}
  end

  defp select(contents, %{range_kind: :all}) do
    {:ok, contents, %{"kind" => "all", "offset" => 0, "bytes" => byte_size(contents)}, false}
  end

  defp select(contents, %{range_kind: :lines} = input) do
    lines = String.split(contents, "\n", trim: false)
    last = input.end_line || length(lines)

    if input.start_line <= length(lines) do
      selected = lines |> Enum.slice((input.start_line - 1)..(last - 1)) |> Enum.join("\n")
      actual_last = min(last, length(lines))

      {:ok, selected, %{"kind" => "lines", "start_line" => input.start_line, "end_line" => actual_last},
       input.start_line > 1 or actual_last < length(lines)}
    else
      {:error, Error.new(:coding_read_range_invalid, %{reason: :start_after_end})}
    end
  end

  defp select(contents, %{range_kind: :bytes} = input) do
    available = byte_size(contents)

    if input.offset <= available do
      requested = input.length || available - input.offset
      count = min(requested, available - input.offset)
      selected = binary_part(contents, input.offset, count)

      if String.valid?(selected) do
        {:ok, selected, %{"kind" => "bytes", "offset" => input.offset, "bytes" => count},
         input.offset + count < available}
      else
        {:error, Error.new(:coding_read_range_invalid, %{reason: :invalid_utf8_boundary})}
      end
    else
      {:error, Error.new(:coding_read_range_invalid, %{reason: :offset_after_end})}
    end
  end

  defp cap(contents, max_bytes) when byte_size(contents) <= max_bytes, do: {contents, false}
  defp cap(contents, max_bytes), do: {utf8_prefix(contents, max_bytes), true}

  defp utf8_prefix(contents, max_bytes) do
    candidate = binary_part(contents, 0, max_bytes)
    if String.valid?(candidate), do: candidate, else: utf8_prefix(contents, max_bytes - 1)
  end

  defp read_access(workspace) do
    if Workspace.permits?(workspace, :read),
      do: :ok,
      else: {:error, Error.new(:coding_read_denied, %{reason: :workspace_access})}
  end

  defp included(%{ignored?: false}), do: :ok
  defp included(decision), do: {:error, Error.new(:coding_path_ignored, ignore_projection(decision))}

  defp resolve_file(workspace, path) do
    case Workspace.resolve(workspace, path, type: :regular) do
      {:error, %Error{details: %{reason: reason}}} when is_binary(reason) ->
        if String.contains?(reason, ":enoent"),
          do: {:error, Error.new(:coding_file_not_found, %{path: path})},
          else: Workspace.resolve(workspace, path, type: :regular)

      result ->
        result
    end
  end

  defp file_stat(opts, resolved) do
    case stat(opts).(resolved.absolute) do
      {:ok, stat} ->
        {:ok, stat}

      {:error, reason} ->
        {:error, Error.new(:coding_read_io_error, %{path: resolved.relative, reason: inspect(reason)})}
    end
  end

  defp file_read(opts, resolved) do
    case read_file(opts).(resolved.absolute) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error, Error.new(:coding_read_io_error, %{path: resolved.relative, reason: inspect(reason)})}
    end
  end

  defp text(contents) do
    if String.valid?(contents) and not String.contains?(contents, <<0>>),
      do: :ok,
      else: {:error, Error.new(:coding_file_binary)}
  end

  defp file_size(size, limit) when size <= limit, do: :ok
  defp file_size(size, limit), do: {:error, Error.new(:coding_file_too_large, %{size: size, limit: limit})}

  defp unchanged(before_stat, after_stat) do
    if before_stat.size == after_stat.size and before_stat.mtime == after_stat.mtime,
      do: :ok,
      else: {:error, Error.new(:coding_file_changed_during_read)}
  end

  defp ceiling(nil, limit), do: {:ok, limit}
  defp ceiling(value, limit) when is_integer(value) and value > 0 and value <= limit, do: {:ok, value}
  defp ceiling(_value, _limit), do: {:error, :requested_limit_exceeds_workspace}

  defp ignore_projection(decision),
    do: %{
      "ignored" => decision.ignored?,
      "kind" => decision.kind,
      "source" => decision.source,
      "pattern" => decision.pattern
    }

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp stat(opts), do: Keyword.get(opts, :stat, &File.stat/1)
  defp read_file(opts), do: Keyword.get(opts, :read_file, &File.read/1)

  defp digest(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
end
