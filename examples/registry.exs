defmodule JidokaExamples.Example do
  @moduledoc false

  @callback name() :: atom()
  @callback title() :: String.t()
  @callback features() :: [atom()]
  @callback summary() :: String.t()
  @callback run(keyword()) :: {:ok, map()} | {:error, term()}
end

defmodule JidokaExamples do
  @moduledoc false

  @root __DIR__

  @examples @root
            |> Path.join("*/manifest.exs")
            |> Path.wildcard()
            |> Enum.sort()
            |> Enum.map(fn path ->
              {manifest, _binding} = Code.eval_file(path)
              Map.put(manifest, :dir, path |> Path.dirname() |> Path.basename())
            end)

  @spec all() :: [map()]
  def all, do: @examples

  @spec names() :: [atom()]
  def names, do: Enum.map(@examples, & &1.name)

  @spec fetch(atom() | String.t()) :: {:ok, map()} | {:error, {:unknown_example, term(), [atom()]}}
  def fetch(name) do
    case Enum.find(@examples, &(Atom.to_string(&1.name) == normalize_name(name))) do
      nil -> {:error, {:unknown_example, name, names()}}
      example -> {:ok, example}
    end
  end

  @spec load(map()) :: {:ok, [module()]} | {:error, term()}
  def load(%{dir: dir, files: files, module: module}) do
    if Code.ensure_loaded?(module) do
      {:ok, []}
    else
      require_files(dir, files)
    end
  end

  @spec run(atom() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(name, opts \\ []) do
    with {:ok, example} <- fetch(name),
         {:ok, _apps} <- Application.ensure_all_started(:jidoka),
         {:ok, _modules} <- load(example),
         :ok <- ensure_example_module(example.module) do
      example.module.run(Keyword.put_new(opts, :example, example))
    end
  end

  @spec feature_labels([atom()]) :: String.t()
  def feature_labels(features) do
    features
    |> Enum.map(&Atom.to_string/1)
    |> Enum.join(", ")
  end

  defp require_files(dir, files) do
    example_root = Path.join(@root, dir)

    if File.dir?(example_root) do
      previous_options = Code.compiler_options()

      modules =
        try do
          Code.compiler_options(ignore_already_consolidated: true)

          files
          |> Enum.flat_map(fn file ->
            example_root
            |> Path.join(file)
            |> Code.require_file()
          end)
          |> Enum.map(fn {module, _binary} -> module end)
        after
          Code.compiler_options(ignore_already_consolidated: previous_options.ignore_already_consolidated)
        end

      {:ok, modules}
    else
      {:error, {:missing_example_dir, example_root}}
    end
  end

  defp ensure_example_module(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :run, 1) do
      :ok
    else
      {:error, {:invalid_example_module, module}}
    end
  end

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.trim_leading(":")
    |> String.replace("-", "_")
  end

  defp normalize_name(name), do: to_string(name)
end
