Code.require_file("catalog.exs", __DIR__)

unless Code.ensure_loaded?(JidokaExamples.MockLLM) do
  for path <- JidokaExamples.Catalog.shared_support_files(__DIR__) do
    Code.require_file(path)
  end
end

defmodule JidokaExamples do
  @moduledoc false

  alias JidokaExamples.{Catalog, Manifest}

  @root __DIR__
  @examples Catalog.load!(@root)

  @spec all() :: [Manifest.t()]
  def all, do: @examples

  @spec names() :: [atom()]
  def names, do: Enum.map(@examples, & &1.name)

  @spec fetch(atom() | String.t()) ::
          {:ok, Manifest.t()} | {:error, {:unknown_example, term(), [atom()]}}
  def fetch(name) do
    case Enum.find(@examples, &(Atom.to_string(&1.name) == normalize_name(name))) do
      nil -> {:error, {:unknown_example, name, names()}}
      example -> {:ok, example}
    end
  end

  @spec load(Manifest.t()) :: {:ok, [module()]} | {:error, term()}
  def load(%Manifest{} = example), do: require_example(example)

  @spec run(atom() | String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(name, opts \\ []) do
    with {:ok, example} <- fetch(name),
         {:ok, _apps} <- Application.ensure_all_started(:jidoka),
         {:ok, _modules} <- load(example),
         :ok <- ensure_example_module(example.module) do
      example.module.run(Keyword.put_new(opts, :example, example))
    end
  end

  @spec capability_labels(Manifest.t()) :: String.t()
  def capability_labels(%Manifest{} = example) do
    example
    |> Catalog.case_declarations()
    |> Enum.flat_map(fn {_scenario, scenario_case} -> scenario_case.proves end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map_join(", ", &Atom.to_string/1)
  end

  defp require_example(example) do
    agent_file = Path.join(example.lib_dir, "agent.ex")
    runner_file = Path.join(example.root, "example.exs")
    library_files = Catalog.source_files(example)
    dependency_files = Enum.reject(library_files, &(&1 == agent_file))

    previous_options = Code.compiler_options()

    try do
      Code.compiler_options(ignore_already_consolidated: true)

      with {:ok, dependency_modules} <- require_parallel(dependency_files),
           {:ok, agent_modules} <- require_one(agent_file),
           {:ok, support_modules} <- require_parallel(Catalog.support_files(example)),
           {:ok, runner_modules} <- require_one(runner_file),
           modules = dependency_modules ++ agent_modules ++ support_modules ++ runner_modules,
           :ok <- validate_namespace(example, modules) do
        {:ok, modules}
      end
    rescue
      exception ->
        {:error, {:load_failed, example.name, Exception.message(exception)}}
    catch
      kind, reason ->
        {:error, {:load_failed, example.name, {kind, reason}}}
    after
      Code.compiler_options(ignore_already_consolidated: previous_options.ignore_already_consolidated)
    end
  end

  defp require_parallel([]), do: {:ok, []}

  defp require_parallel(files) do
    case Kernel.ParallelCompiler.require(files, return_diagnostics: true) do
      {:ok, modules, warnings} ->
        if diagnostics_empty?(warnings) do
          {:ok, modules}
        else
          {:error, {:compile_warnings, warnings}}
        end

      {:error, errors, warnings} ->
        {:error, {:compile_failed, errors, warnings}}
    end
  end

  defp require_one(path) do
    if File.regular?(path) do
      {compiled, diagnostics} = Code.with_diagnostics(fn -> Code.require_file(path) end)

      if diagnostics_empty?(diagnostics) do
        {:ok, Enum.map(compiled || [], &elem(&1, 0))}
      else
        {:error, {:compile_warnings, diagnostics}}
      end
    else
      {:error, {:missing_example_file, path}}
    end
  end

  defp validate_namespace(example, modules) do
    expected = "Elixir.JidokaExamples.#{Macro.camelize(example.dir)}"
    invalid = Enum.reject(modules, &(Atom.to_string(&1) |> String.starts_with?(expected)))

    if invalid == [] do
      :ok
    else
      {:error, {:invalid_example_namespace, expected, invalid}}
    end
  end

  defp ensure_example_module(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :run, 1) do
      :ok
    else
      {:error, {:invalid_example_module, module}}
    end
  end

  defp diagnostics_empty?(%{compile_warnings: compile, runtime_warnings: runtime}) do
    compile == [] and runtime == []
  end

  defp diagnostics_empty?(diagnostics) when is_list(diagnostics), do: diagnostics == []

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.trim_leading(":")
    |> String.replace("-", "_")
  end

  defp normalize_name(name), do: to_string(name)
end
