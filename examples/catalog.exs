unless Code.ensure_loaded?(JidokaExamples.Manifest) do
  Code.require_file("_support/model.ex", __DIR__)
end

defmodule JidokaExamples.Example do
  @moduledoc false

  @callback run(keyword()) :: {:ok, term()} | {:error, term()}
end

defmodule JidokaExamples.Catalog do
  @moduledoc false

  alias JidokaExamples.{Capabilities, Manifest, Scenario, ScenarioCase, ShowcaseSurface}

  @allowed_keys [:agent, :module, :name, :scenarios, :summary, :surfaces, :title, :version]
  @required_keys @allowed_keys
  @scenario_keys [:cases, :execution, :id, :intent, :title]
  @case_keys [:id, :proves, :uses]
  @surface_keys [:livebook, :showcase]
  @showcase_keys [:live_view, :route, :sources, :tests, :view]
  @version 2
  @reserved_dirs ["_support"]
  @identifier_pattern ~r/^[a-z][a-z0-9_]{0,63}$/
  @module_pattern ~r/^(?:Elixir\.)?[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)+$/

  @spec load(String.t()) :: {[Manifest.t()], [map()]}
  def load(root \\ __DIR__) do
    root = Path.expand(root)

    root
    |> Path.join("*/manifest.yaml")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce({[], []}, fn path, {manifests, errors} ->
      case load_manifest(path, root) do
        {:ok, manifest} -> {[manifest | manifests], errors}
        {:error, manifest_errors} -> {manifests, errors ++ manifest_errors}
      end
    end)
    |> then(fn {manifests, errors} -> {Enum.reverse(manifests), errors} end)
  end

  @spec load!(String.t()) :: [Manifest.t()]
  def load!(root \\ __DIR__) do
    case load(root) do
      {manifests, []} ->
        manifests

      {_manifests, errors} ->
        message = Enum.map_join(errors, "\n", &"  * #{relative_error(&1)}")
        raise ArgumentError, "invalid Jidoka example catalog:\n#{message}"
    end
  end

  @spec scenario_dirs(String.t()) :: [String.t()]
  def scenario_dirs(root \\ __DIR__) do
    root
    |> Path.expand()
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.reject(&(Path.basename(&1) in @reserved_dirs))
    |> Enum.reject(&(Path.basename(&1) |> String.starts_with?(".")))
    |> Enum.sort()
  end

  @spec source_files(Manifest.t()) :: [String.t()]
  def source_files(%Manifest{} = manifest) do
    manifest.lib_dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @spec shared_support_files(String.t()) :: [String.t()]
  def shared_support_files(root \\ __DIR__) do
    root
    |> Path.expand()
    |> Path.join("_support/shared/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @spec support_files(Manifest.t()) :: [String.t()]
  def support_files(%Manifest{} = manifest) do
    manifest.support_dir
    |> Path.join("**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @spec test_files(Manifest.t()) :: [String.t()]
  def test_files(%Manifest{} = manifest), do: manifest.test_files

  @spec case_declarations(Manifest.t()) :: [{Scenario.t(), ScenarioCase.t()}]
  def case_declarations(%Manifest{} = manifest) do
    for scenario <- manifest.scenarios, scenario_case <- scenario.cases do
      {scenario, scenario_case}
    end
  end

  @spec fetch_case(Manifest.t(), atom(), atom()) ::
          {:ok, {Scenario.t(), ScenarioCase.t()}} | {:error, :unknown_case}
  def fetch_case(%Manifest{} = manifest, scenario_id, case_id) do
    Enum.find_value(manifest.scenarios, {:error, :unknown_case}, fn scenario ->
      if scenario.id == scenario_id do
        case Enum.find(scenario.cases, &(&1.id == case_id)) do
          nil -> nil
          scenario_case -> {:ok, {scenario, scenario_case}}
        end
      end
    end)
  end

  defp load_manifest(path, root) do
    with {:ok, value} <- read_manifest(path),
         :ok <- validate_map(value, path),
         {:ok, manifest} <- normalize(value, path, root),
         :ok <- validate_local_files(manifest) do
      {:ok, manifest}
    else
      {:error, errors} when is_list(errors) -> {:error, errors}
      {:error, message} -> {:error, [error(path, message)]}
    end
  end

  defp read_manifest(path) do
    case YamlElixir.read_all_from_file(path) do
      {:ok, [value]} -> {:ok, decode_manifest(value)}
      {:ok, documents} -> {:error, "manifest must contain one YAML document, got #{length(documents)}"}
      {:error, exception} -> {:error, "cannot parse YAML manifest: #{Exception.message(exception)}"}
    end
  end

  defp decode_manifest(value) when is_map(value) do
    value
    |> decode_keys(@allowed_keys)
    |> update_value(:name, &decode_identifier/1)
    |> update_value(:module, &decode_module/1)
    |> update_value(:agent, &decode_module/1)
    |> update_value(:scenarios, &decode_scenarios/1)
    |> update_value(:surfaces, &decode_surfaces/1)
  end

  defp decode_manifest(value), do: value

  defp decode_scenarios(scenarios) when is_list(scenarios), do: Enum.map(scenarios, &decode_scenario/1)
  defp decode_scenarios(scenarios), do: scenarios

  defp decode_scenario(scenario) when is_map(scenario) do
    scenario
    |> decode_keys(@scenario_keys)
    |> update_value(:id, &decode_identifier/1)
    |> update_value(:execution, &decode_execution/1)
    |> update_value(:cases, &decode_cases/1)
  end

  defp decode_scenario(scenario), do: scenario

  defp decode_cases(cases) when is_list(cases), do: Enum.map(cases, &decode_case/1)
  defp decode_cases(cases), do: cases

  defp decode_case(scenario_case) when is_map(scenario_case) do
    scenario_case
    |> decode_keys(@case_keys)
    |> update_value(:id, &decode_identifier/1)
    |> update_value(:proves, &decode_symbols/1)
    |> update_value(:uses, &decode_symbols/1)
  end

  defp decode_case(scenario_case), do: scenario_case

  defp decode_surfaces(surfaces) when is_map(surfaces) do
    surfaces
    |> decode_keys(@surface_keys)
    |> update_value(:showcase, &decode_showcase/1)
  end

  defp decode_surfaces(surfaces), do: surfaces

  defp decode_showcase(showcase) when is_map(showcase) do
    showcase
    |> decode_keys(@showcase_keys)
    |> update_value(:live_view, &decode_module/1)
    |> update_value(:view, &decode_module/1)
  end

  defp decode_showcase(showcase), do: showcase

  defp decode_keys(map, allowed_keys) do
    key_lookup = Map.new(allowed_keys, &{Atom.to_string(&1), &1})
    Map.new(map, fn {key, value} -> {Map.get(key_lookup, key, key), value} end)
  end

  defp update_value(map, key, fun) do
    case Map.fetch(map, key) do
      {:ok, value} -> Map.put(map, key, fun.(value))
      :error -> map
    end
  end

  defp decode_identifier(value) when is_binary(value) do
    if Regex.match?(@identifier_pattern, value), do: String.to_atom(value), else: value
  end

  defp decode_identifier(value), do: value

  defp decode_execution("deterministic"), do: :deterministic
  defp decode_execution("external"), do: :external
  defp decode_execution(value), do: value

  defp decode_symbols(values) when is_list(values), do: Enum.map(values, &decode_symbol/1)
  defp decode_symbols(values), do: values

  defp decode_symbol(value) when is_binary(value) do
    known = Capabilities.names() ++ Capabilities.component_names()
    Enum.find(known, value, &(Atom.to_string(&1) == value))
  end

  defp decode_symbol(value), do: value

  defp decode_module(value) when is_binary(value) do
    if Regex.match?(@module_pattern, value) do
      value
      |> String.trim_leading("Elixir.")
      |> then(&String.to_atom("Elixir.#{&1}"))
    else
      value
    end
  end

  defp decode_module(value), do: value

  defp validate_map(value, path) when is_map(value) do
    missing = @required_keys -- Map.keys(value)
    unknown = Map.keys(value) -- @allowed_keys

    errors =
      []
      |> maybe_error(missing != [], path, "missing keys: #{inspect(Enum.sort(missing))}")
      |> maybe_error(unknown != [], path, "unknown keys: #{inspect(Enum.sort(unknown))}")

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp validate_map(_value, path), do: {:error, [error(path, "manifest must return a map")]}

  defp normalize(value, path, root) do
    dir = path |> Path.dirname() |> Path.basename()
    scenario_root = Path.join(root, dir)
    name = Map.get(value, :name)
    scenarios = Map.get(value, :scenarios)
    surfaces = Map.get(value, :surfaces)

    errors =
      []
      |> maybe_error(not is_atom(name), path, "name must be a snake_case identifier")
      |> maybe_error(is_atom(name) and Atom.to_string(name) != dir, path, "name must match folder #{inspect(dir)}")
      |> maybe_error(not non_empty_string?(Map.get(value, :title)), path, "title must be a non-empty string")
      |> maybe_error(not non_empty_string?(Map.get(value, :summary)), path, "summary must be a non-empty string")
      |> maybe_error(not module_atom?(Map.get(value, :module)), path, "module must be a valid module name")
      |> maybe_error(not module_atom?(Map.get(value, :agent)), path, "agent must be a valid module name")
      |> maybe_error(Map.get(value, :version) != @version, path, "version must be #{@version}")
      |> Kernel.++(scenario_errors(scenarios, path))
      |> Kernel.++(surface_errors(surfaces, path))

    if errors == [] do
      {:ok,
       %Manifest{
         agent: value.agent,
         dir: dir,
         lib_dir: Path.join(scenario_root, "lib"),
         livebook: Path.join(scenario_root, "#{dir}.livemd"),
         manifest: path,
         module: value.module,
         name: value.name,
         readme: Path.join(scenario_root, "README.md"),
         root: scenario_root,
         scenarios: normalize_scenarios(scenarios),
         showcase: normalize_showcase(Map.get(surfaces, :showcase)),
         summary: value.summary,
         support_dir: Path.join(scenario_root, "support"),
         test_files: discover_test_files(scenario_root),
         title: value.title,
         version: value.version
       }}
    else
      {:error, errors}
    end
  end

  defp scenario_errors(scenarios, path) when is_list(scenarios) and scenarios != [] do
    ids = Enum.map(scenarios, &map_value(&1, :id))

    duplicate_id_errors(ids, path, "scenario") ++
      Enum.flat_map(scenarios, &scenario_errors(&1, path, map_value(&1, :id)))
  end

  defp scenario_errors(_scenarios, path), do: [error(path, "scenarios must be a non-empty list")]

  defp scenario_errors(scenario, path, id) when is_map(scenario) do
    missing = @scenario_keys -- Map.keys(scenario)
    unknown = Map.keys(scenario) -- @scenario_keys
    cases = Map.get(scenario, :cases)

    []
    |> maybe_error(missing != [], path, "scenario #{inspect(id)} is missing keys: #{inspect(Enum.sort(missing))}")
    |> maybe_error(unknown != [], path, "scenario #{inspect(id)} has unknown keys: #{inspect(Enum.sort(unknown))}")
    |> maybe_error(not is_atom(id), path, "scenario id must be a snake_case identifier: #{inspect(id)}")
    |> maybe_error(
      not non_empty_string?(Map.get(scenario, :title)),
      path,
      "scenario #{inspect(id)} title must be a non-empty string"
    )
    |> maybe_error(
      not non_empty_string?(Map.get(scenario, :intent)),
      path,
      "scenario #{inspect(id)} intent must be a non-empty string"
    )
    |> maybe_error(
      Map.get(scenario, :execution) not in [:deterministic, :external],
      path,
      "scenario #{inspect(id)} has an invalid execution mode"
    )
    |> Kernel.++(case_errors(cases, path, id))
  end

  defp scenario_errors(_scenario, path, id), do: [error(path, "scenario #{inspect(id)} must be a map")]

  defp case_errors(cases, path, scenario_id) when is_list(cases) and cases != [] do
    ids = Enum.map(cases, &map_value(&1, :id))

    duplicate_id_errors(ids, path, "case in scenario #{inspect(scenario_id)}") ++
      Enum.flat_map(cases, &case_errors(&1, path, scenario_id, map_value(&1, :id)))
  end

  defp case_errors(_cases, path, scenario_id) do
    [error(path, "scenario #{inspect(scenario_id)} cases must be a non-empty list")]
  end

  defp case_errors(scenario_case, path, scenario_id, case_id) when is_map(scenario_case) do
    missing = @case_keys -- Map.keys(scenario_case)
    unknown = Map.keys(scenario_case) -- @case_keys
    proves = Map.get(scenario_case, :proves)
    uses = Map.get(scenario_case, :uses)
    label = "case #{inspect(case_id)} in scenario #{inspect(scenario_id)}"

    []
    |> maybe_error(missing != [], path, "#{label} is missing keys: #{inspect(Enum.sort(missing))}")
    |> maybe_error(unknown != [], path, "#{label} has unknown keys: #{inspect(Enum.sort(unknown))}")
    |> maybe_error(not is_atom(case_id), path, "#{label} id must be a snake_case identifier")
    |> Kernel.++(proof_value_errors(proves, path, label))
    |> Kernel.++(use_value_errors(uses, path, label))
    |> maybe_error(overlap?(proves, uses), path, "#{label} has overlapping proves and uses values")
  end

  defp case_errors(_scenario_case, path, scenario_id, case_id) do
    [error(path, "case #{inspect(case_id)} in scenario #{inspect(scenario_id)} must be a map")]
  end

  defp proof_value_errors(values, path, label) when is_list(values) and values != [] do
    []
    |> maybe_error(Enum.uniq(values) != values, path, "#{label} proves contains duplicates")
    |> Kernel.++(
      values
      |> Enum.reject(&Capabilities.known?/1)
      |> Enum.map(&error(path, "#{label} has unknown capability in proves: #{inspect(&1)}"))
    )
  end

  defp proof_value_errors(_values, path, label), do: [error(path, "#{label} proves must be a non-empty list")]

  defp use_value_errors(values, path, label) when is_list(values) do
    []
    |> maybe_error(Enum.uniq(values) != values, path, "#{label} uses contains duplicates")
    |> Kernel.++(
      values
      |> Enum.reject(&Capabilities.known_use?/1)
      |> Enum.map(&error(path, "#{label} has unknown capability or component in uses: #{inspect(&1)}"))
    )
  end

  defp use_value_errors(_values, path, label), do: [error(path, "#{label} uses must be a list")]

  defp surface_errors(surfaces, path) when is_map(surfaces) do
    missing = @surface_keys -- Map.keys(surfaces)
    unknown = Map.keys(surfaces) -- @surface_keys

    []
    |> maybe_error(missing != [], path, "surfaces is missing keys: #{inspect(Enum.sort(missing))}")
    |> maybe_error(unknown != [], path, "surfaces has unknown keys: #{inspect(Enum.sort(unknown))}")
    |> maybe_error(Map.get(surfaces, :livebook) != true, path, "surfaces.livebook must be true")
    |> Kernel.++(showcase_errors(Map.get(surfaces, :showcase), path))
  end

  defp surface_errors(_surfaces, path), do: [error(path, "surfaces must be a map")]

  defp showcase_errors(nil, _path), do: []
  defp showcase_errors(false, _path), do: []

  defp showcase_errors(showcase, path) when is_map(showcase) do
    missing = @showcase_keys -- Map.keys(showcase)
    unknown = Map.keys(showcase) -- @showcase_keys
    route = Map.get(showcase, :route)
    tests = Map.get(showcase, :tests)
    sources = Map.get(showcase, :sources)

    []
    |> maybe_error(missing != [], path, "showcase is missing keys: #{inspect(Enum.sort(missing))}")
    |> maybe_error(unknown != [], path, "showcase has unknown keys: #{inspect(Enum.sort(unknown))}")
    |> maybe_error(
      not (non_empty_string?(route) and String.starts_with?(route, "/")),
      path,
      "showcase route must start with /"
    )
    |> maybe_error(
      not module_atom?(Map.get(showcase, :live_view)),
      path,
      "showcase live_view must be a valid module name"
    )
    |> maybe_error(not module_atom?(Map.get(showcase, :view)), path, "showcase view must be a valid module name")
    |> maybe_error(not relative_paths?(tests), path, "showcase tests must be non-empty safe relative paths")
    |> maybe_error(not relative_paths?(sources), path, "showcase sources must be non-empty safe relative paths")
    |> maybe_error(not showcase_modules?(showcase), path, "showcase modules must use the JidokaShowcase namespace")
    |> maybe_error(not showcase_test_paths?(tests), path, "showcase tests must stay under showcase/test")
    |> maybe_error(
      not showcase_source_paths?(sources, Path.basename(Path.dirname(path))),
      path,
      "showcase sources must stay under this example or showcase"
    )
  end

  defp showcase_errors(_showcase, path), do: [error(path, "surfaces.showcase must be nil, false, or a map")]

  defp normalize_scenarios(scenarios) do
    Enum.map(scenarios, fn scenario ->
      %Scenario{
        cases:
          Enum.map(scenario.cases, fn scenario_case ->
            %ScenarioCase{
              id: scenario_case.id,
              proves: Enum.sort(scenario_case.proves),
              uses: Enum.sort(scenario_case.uses)
            }
          end),
        execution: scenario.execution,
        id: scenario.id,
        intent: String.trim(scenario.intent),
        title: String.trim(scenario.title)
      }
    end)
  end

  defp normalize_showcase(value) when value in [nil, false], do: nil

  defp normalize_showcase(showcase) do
    %ShowcaseSurface{
      live_view: showcase.live_view,
      route: showcase.route,
      sources: Enum.sort(showcase.sources),
      tests: Enum.sort(showcase.tests),
      view: showcase.view
    }
  end

  defp discover_test_files(scenario_root) do
    scenario_root
    |> Path.join("**/*_test.exs")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp validate_local_files(manifest) do
    required = [
      {"README", manifest.readme, :file},
      {"agent", Path.join(manifest.lib_dir, "agent.ex"), :file},
      {"example runner", Path.join(manifest.root, "example.exs"), :file},
      {"library folder", manifest.lib_dir, :dir},
      {"Livebook", manifest.livebook, :file}
    ]

    errors =
      Enum.flat_map(required, fn {label, path, type} ->
        valid? = if type == :dir, do: File.dir?(path), else: File.regular?(path)
        if valid?, do: [], else: [error(manifest.manifest, "missing #{label}: #{path}")]
      end) ++
        maybe_file_error(source_files(manifest) == [], manifest, "library folder has no .ex files") ++
        maybe_file_error(manifest.test_files == [], manifest, "no proof test files were found")

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp maybe_file_error(true, manifest, message), do: [error(manifest.manifest, message)]
  defp maybe_file_error(false, _manifest, _message), do: []

  defp duplicate_id_errors(ids, path, label) do
    ids
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(fn {id, _count} -> error(path, "duplicate #{label} id: #{inspect(id)}") end)
  end

  defp overlap?(proves, uses) when is_list(proves) and is_list(uses) do
    not MapSet.disjoint?(MapSet.new(proves), MapSet.new(uses))
  end

  defp overlap?(_proves, _uses), do: false

  defp relative_paths?(values) when is_list(values) and values != [] do
    Enum.all?(values, &(non_empty_string?(&1) and safe_relative_path?(&1)))
  end

  defp relative_paths?(_values), do: false

  defp safe_relative_path?(path) do
    Path.type(path) != :absolute and ".." not in Path.split(path)
  end

  defp showcase_modules?(showcase) when is_map(showcase) do
    Enum.all?([Map.get(showcase, :live_view), Map.get(showcase, :view)], fn module ->
      module_atom?(module) and String.starts_with?(Atom.to_string(module), "Elixir.JidokaShowcase")
    end)
  end

  defp showcase_test_paths?(paths) when is_list(paths) do
    Enum.all?(paths, &String.starts_with?(&1, "showcase/test/"))
  end

  defp showcase_test_paths?(_paths), do: false

  defp showcase_source_paths?(paths, example_dir) when is_list(paths) do
    Enum.all?(paths, fn path ->
      String.starts_with?(path, "examples/#{example_dir}/") or
        String.starts_with?(path, "showcase/")
    end)
  end

  defp showcase_source_paths?(_paths, _example_dir), do: false

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp module_atom?(value), do: is_atom(value) and String.starts_with?(Atom.to_string(value), "Elixir.")
  defp map_value(value, key) when is_map(value), do: Map.get(value, key)
  defp map_value(_value, _key), do: nil

  defp maybe_error(errors, true, path, message), do: errors ++ [error(path, message)]
  defp maybe_error(errors, false, _path, _message), do: errors

  defp error(path, message) do
    %{scope: Path.basename(Path.dirname(path)), path: path, message: message}
  end

  defp relative_error(error), do: "#{error.path}: #{error.message}"
end
