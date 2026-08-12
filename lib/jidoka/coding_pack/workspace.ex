defmodule Jidoka.CodingPack.Workspace do
  @moduledoc "Trusted workspace boundary for first-party coding operations."

  alias Jidoka.CodingPack.Error

  @version 1
  @access_classes [:read, :write, :shell, :git, :verify]
  @default_instruction_files ["AGENTS.md", ".jido/instructions.md"]
  @default_limits %{
    max_file_bytes: 1_048_576,
    max_result_bytes: 262_144,
    max_instruction_bytes: 65_536,
    max_instruction_files: 32,
    max_search_files: 10_000,
    max_search_results: 200
  }
  @keys [
    :root,
    :access,
    :ignore_files,
    :trusted_exclusions,
    :instruction_files,
    :limits,
    :execution_profile
  ]

  @enforce_keys [
    :root,
    :root_digest,
    :access,
    :ignore_files,
    :trusted_exclusions,
    :instruction_files,
    :limits
  ]
  defstruct version: @version,
            root: nil,
            root_digest: nil,
            access: [],
            ignore_files: [".gitignore"],
            trusted_exclusions: [],
            instruction_files: @default_instruction_files,
            limits: @default_limits,
            execution_profile: nil

  @type access_class :: :read | :write | :shell | :git | :verify
  @type t :: %__MODULE__{
          version: 1,
          root: String.t(),
          root_digest: String.t(),
          access: [access_class()],
          ignore_files: [String.t()],
          trusted_exclusions: [String.t()],
          instruction_files: [String.t()],
          limits: map(),
          execution_profile: String.t() | nil
        }

  @doc "Builds a workspace from trusted host configuration."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Jidoka.Schema.normalize_attrs(attrs)

    with :ok <- known_keys(attrs),
         root when is_binary(root) <- Jidoka.Schema.get_key(attrs, :root),
         {:ok, root} <- canonical_existing(root),
         {:ok, %{type: :directory}} <- File.stat(root),
         {:ok, access} <- access(Jidoka.Schema.get_key(attrs, :access, [:read])),
         {:ok, ignore_files} <- safe_relative_list(Jidoka.Schema.get_key(attrs, :ignore_files, [".gitignore"])),
         {:ok, trusted_exclusions} <-
           pattern_list(Jidoka.Schema.get_key(attrs, :trusted_exclusions, [])),
         {:ok, instruction_files} <-
           safe_relative_list(Jidoka.Schema.get_key(attrs, :instruction_files, @default_instruction_files)),
         {:ok, limits} <- limits(Jidoka.Schema.get_key(attrs, :limits, %{})),
         {:ok, execution_profile} <-
           optional_id(Jidoka.Schema.get_key(attrs, :execution_profile)) do
      {:ok,
       %__MODULE__{
         root: root,
         root_digest: digest(root),
         access: access,
         ignore_files: ignore_files,
         trusted_exclusions: trusted_exclusions,
         instruction_files: instruction_files,
         limits: limits,
         execution_profile: execution_profile
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:workspace_invalid, %{reason: inspect(reason)})}
      reason -> {:error, Error.new(:workspace_invalid, %{reason: inspect(reason)})}
    end
  end

  @doc "Builds a trusted workspace or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, workspace} -> workspace
      {:error, error} -> raise ArgumentError, inspect(error)
    end
  end

  @doc "Returns a portable workspace projection without the host path."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = workspace) do
    %{
      "version" => workspace.version,
      "root_digest" => workspace.root_digest,
      "access" => Enum.map(workspace.access, &Atom.to_string/1),
      "ignore_files" => workspace.ignore_files,
      "instruction_files" => workspace.instruction_files,
      "limits" => Map.new(workspace.limits, fn {key, value} -> {Atom.to_string(key), value} end),
      "execution_profile" => workspace.execution_profile
    }
  end

  @doc "Resolves a relative path inside the canonical workspace boundary."
  @spec resolve(t(), String.t(), keyword()) ::
          {:ok, %{absolute: String.t(), relative: String.t(), type: atom()}}
          | {:error, Error.t()}
  def resolve(%__MODULE__{} = workspace, path, opts \\ []) do
    allow_missing? = Keyword.get(opts, :allow_missing, false)

    with :ok <- relative_input(path),
         parts = path_parts(path),
         {:ok, absolute, type} <- walk(workspace.root, workspace.root, parts, allow_missing?, 0),
         true <- within?(workspace.root, absolute),
         :ok <- allowed_type(type, Keyword.get(opts, :type, :any)) do
      relative = Path.relative_to(absolute, workspace.root) |> normalize_relative()
      {:ok, %{absolute: absolute, relative: relative, type: type}}
    else
      {:error, reason} -> path_error(path, reason)
      false -> path_error(path, :outside_workspace)
    end
  end

  @doc "Returns a portable policy resource summary for a later coding operation."
  @spec resource(t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def resource(%__MODULE__{} = workspace, action, path, facts \\ %{})
      when is_binary(action) and is_map(facts) do
    with {:ok, resolved} <- resolve(workspace, path, allow_missing: Map.get(facts, :allow_missing, false)) do
      {:ok,
       %{
         "kind" => "coding_workspace",
         "action" => action,
         "workspace" => workspace.root_digest,
         "path" => resolved.relative,
         "path_type" => Atom.to_string(resolved.type),
         "execution_profile" => workspace.execution_profile
       }}
    end
  end

  @doc "Returns true when an access class was granted by the trusted host."
  @spec permits?(t(), access_class()) :: boolean()
  def permits?(%__MODULE__{access: access}, class), do: class in access

  defp known_keys(attrs) do
    case Map.keys(attrs) -- @keys do
      [] -> :ok
      keys -> {:error, Error.new(:workspace_unknown_keys, %{keys: Enum.map(keys, &to_string/1) |> Enum.sort()})}
    end
  end

  defp access(values) when is_list(values) do
    values = Enum.map(values, &normalize_access/1)

    if values != [] and Enum.all?(values, &(&1 in @access_classes)),
      do: {:ok, Enum.uniq(values)},
      else: {:error, :invalid_workspace_access}
  end

  defp access(_value), do: {:error, :invalid_workspace_access}
  defp normalize_access(value) when value in @access_classes, do: value
  defp normalize_access(value) when is_binary(value), do: Enum.find(@access_classes, &(Atom.to_string(&1) == value))
  defp normalize_access(_value), do: nil

  defp safe_relative_list(values) when is_list(values) do
    if values != [] and Enum.all?(values, &safe_relative?/1),
      do: {:ok, Enum.uniq(values)},
      else: {:error, :invalid_workspace_relative_paths}
  end

  defp safe_relative_list(_value), do: {:error, :invalid_workspace_relative_paths}

  defp pattern_list(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and String.valid?(&1) and &1 != "")),
      do: {:ok, Enum.uniq(values)},
      else: {:error, :invalid_workspace_exclusions}
  end

  defp pattern_list(_value), do: {:error, :invalid_workspace_exclusions}

  defp limits(input) when is_map(input) or is_list(input) do
    input = Jidoka.Schema.normalize_attrs(input)

    case Enum.all?(Map.keys(input), &Map.has_key?(@default_limits, &1)) do
      true -> validate_limits(Map.merge(@default_limits, input))
      false -> {:error, :invalid_workspace_limit_keys}
    end
  end

  defp limits(_value), do: {:error, :invalid_workspace_limits}

  defp validate_limits(limits) do
    if Enum.all?(limits, fn {_key, value} -> is_integer(value) and value > 0 end),
      do: {:ok, limits},
      else: {:error, :invalid_workspace_limits}
  end

  defp optional_id(nil), do: {:ok, nil}
  defp optional_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp optional_id(_value), do: {:error, :invalid_execution_profile}

  defp relative_input(path) when is_binary(path) do
    cond do
      not String.valid?(path) -> {:error, :invalid_encoding}
      path == "" -> {:error, :empty_path}
      Path.type(path) != :relative -> {:error, :absolute_path}
      Enum.any?(Path.split(path), &(&1 == "..")) -> {:error, :parent_traversal}
      true -> :ok
    end
  end

  defp relative_input(_path), do: {:error, :invalid_path}

  defp safe_relative?(path) when is_binary(path) do
    String.valid?(path) and path != "" and Path.type(path) == :relative and
      not Enum.any?(Path.split(path), &(&1 in ["..", "."]))
  end

  defp safe_relative?(_path), do: false

  defp path_parts("."), do: []
  defp path_parts(path), do: Enum.reject(Path.split(path), &(&1 in ["", "."]))

  defp walk(_root, _current, _parts, _allow_missing?, hops) when hops > 32,
    do: {:error, :too_many_symbolic_links}

  defp walk(_root, current, [], _allow_missing?, _hops) do
    case File.lstat(current) do
      {:ok, stat} -> {:ok, Path.expand(current), stat.type}
      {:error, reason} -> {:error, reason}
    end
  end

  defp walk(root, current, [part | rest], allow_missing?, hops) do
    candidate = Path.expand(Path.join(current, part))

    if within?(root, candidate) do
      walk_candidate(root, candidate, rest, allow_missing?, hops, File.lstat(candidate))
    else
      {:error, :outside_workspace}
    end
  end

  defp walk_candidate(root, candidate, rest, allow_missing?, hops, {:ok, %{type: :symlink}}),
    do: walk_symlink(root, candidate, rest, allow_missing?, hops)

  defp walk_candidate(root, candidate, rest, allow_missing?, hops, {:ok, %{type: :directory}}),
    do: walk(root, candidate, rest, allow_missing?, hops)

  defp walk_candidate(_root, candidate, [], _allow_missing?, _hops, {:ok, stat}),
    do: {:ok, candidate, stat.type}

  defp walk_candidate(_root, _candidate, _rest, _allow_missing?, _hops, {:ok, _stat}),
    do: {:error, :not_directory}

  defp walk_candidate(root, candidate, rest, true, _hops, {:error, :enoent}) do
    missing = Path.expand(Path.join([candidate | rest]))
    if within?(root, missing), do: {:ok, missing, :missing}, else: {:error, :outside_workspace}
  end

  defp walk_candidate(_root, _candidate, _rest, _allow_missing?, _hops, {:error, reason}),
    do: {:error, reason}

  defp walk_symlink(root, candidate, rest, allow_missing?, hops) do
    with {:ok, target} <- File.read_link(candidate),
         target = symlink_target(candidate, target),
         {:ok, target} <- canonical_existing(target),
         true <- within?(root, target) do
      walk(root, target, rest, allow_missing?, hops + 1)
    else
      false -> {:error, :symlink_escape}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_existing(path) do
    path |> Path.expand() |> resolve_canonical(0)
  end

  defp resolve_canonical(_path, hops) when hops > 32, do: {:error, :too_many_symbolic_links}

  defp resolve_canonical(path, hops) do
    [root | parts] = Path.split(Path.expand(path))
    walk_canonical(root, parts, hops)
  end

  defp walk_canonical(current, [], _hops), do: {:ok, current}

  defp walk_canonical(current, [part | rest], hops) do
    candidate = Path.join(current, part)

    case File.lstat(candidate) do
      {:ok, %{type: :symlink}} ->
        with {:ok, target} <- File.read_link(candidate) do
          target = symlink_target(candidate, target)
          resolve_canonical(Path.join([target | rest]), hops + 1)
        end

      {:ok, _stat} ->
        walk_canonical(candidate, rest, hops)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp symlink_target(candidate, target) do
    if Path.type(target) == :absolute,
      do: Path.expand(target),
      else: Path.expand(target, Path.dirname(candidate))
  end

  defp within?(root, path),
    do: path == root or String.starts_with?(path, root <> "/") or String.starts_with?(path, root <> "\\")

  defp allowed_type(type, :any) when type in [:regular, :directory, :missing], do: :ok
  defp allowed_type(type, type), do: :ok
  defp allowed_type(type, expected), do: {:error, {:unexpected_path_type, expected, type}}

  defp normalize_relative("."), do: "."
  defp normalize_relative(path), do: String.replace(path, "\\", "/")

  defp path_error(path, reason),
    do: {:error, Error.new(:workspace_path_rejected, %{path: inspect(path), reason: inspect(reason)})}

  defp digest(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
end
