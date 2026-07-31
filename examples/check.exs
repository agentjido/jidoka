Code.require_file("catalog.exs", __DIR__)

unless Code.ensure_loaded?(JidokaExamples.Timeouts) do
  Code.require_file("_support/timeouts.ex", __DIR__)
end

unless Code.ensure_loaded?(JidokaExamples.Planner) do
  Code.require_file("_support/planner.ex", __DIR__)
end

unless Code.ensure_loaded?(JidokaExamples.Executor) do
  Code.require_file("_support/executor.ex", __DIR__)
end

unless Code.ensure_loaded?(JidokaExamples.Reporter) do
  Code.require_file("_support/reporter.ex", __DIR__)
end

defmodule JidokaExamples.Check do
  @moduledoc false

  alias JidokaExamples.{Catalog, Executor, GateResult, Planner, ProofReport, Reporter}

  @spec run(keyword()) :: ProofReport.t()
  def run(opts \\ []) do
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()
    examples_root = Path.join(root, "examples")
    {examples, catalog_errors} = Catalog.load(examples_root)

    with {:ok, opts} <- add_changed_paths(opts, root),
         :ok <- validate_catalog_for_selection(examples, catalog_errors, opts),
         {:ok, selection} <- Planner.plan(examples, opts, root) do
      catalog_gate = catalog_gate(examples, catalog_errors, opts, root)
      static_gate = static_gate(examples, selection.examples, root)

      execution =
        if catalog_gate.status == :ok and static_gate.status == :ok and
             Keyword.get(opts, :subprocesses, true) do
          Executor.run(selection.gates, verbose: Keyword.get(opts, :verbose, false))
        else
          skipped = Enum.map(selection.gates, &skipped_gate(&1, "Execution was disabled or an earlier gate failed."))
          %{artifacts: %{}, gates: skipped}
        end

      selection
      |> Reporter.build([catalog_gate, static_gate] ++ execution.gates, execution.artifacts)
      |> publication_gate(examples, opts, root)
    else
      {:error, message} -> failed_report(message, opts)
    end
  end

  @spec proof_document(ProofReport.t(), [JidokaExamples.Manifest.t()]) :: String.t()
  def proof_document(report, examples), do: Reporter.document(report, examples)

  defp validate_catalog_for_selection(examples, errors, opts) do
    relevant = relevant_catalog_errors(errors, opts)

    cond do
      examples == [] and relevant == [] -> {:error, "The example catalog is empty."}
      relevant != [] -> {:error, Enum.map_join(relevant, "\n", &catalog_error/1)}
      true -> :ok
    end
  end

  defp relevant_catalog_errors(errors, opts) do
    case Keyword.get(opts, :example) do
      nil -> errors
      name -> Enum.filter(errors, &(&1.scope == normalize_name(name)))
    end
  end

  defp catalog_gate(examples, catalog_errors, opts, root) do
    errors =
      relevant_catalog_errors(catalog_errors, opts)
      |> Enum.map(&catalog_error/1)
      |> Kernel.++(missing_manifest_errors(root, opts))
      |> Kernel.++(duplicate_errors(examples))

    gate(:catalog, :catalog, :catalog, errors)
  end

  defp missing_manifest_errors(root, opts) do
    examples_root = Path.join(root, "examples")

    manifest_dirs =
      examples_root
      |> Path.join("*/manifest.exs")
      |> Path.wildcard()
      |> MapSet.new(&Path.dirname/1)

    examples_root
    |> Catalog.scenario_dirs()
    |> MapSet.new()
    |> MapSet.difference(manifest_dirs)
    |> Enum.sort()
    |> Enum.filter(fn path ->
      case Keyword.get(opts, :example) do
        nil -> true
        name -> Path.basename(path) == normalize_name(name)
      end
    end)
    |> Enum.map(&"#{Path.relative_to(&1, root)}: missing manifest.exs")
  end

  defp duplicate_errors(examples) do
    showcased = Enum.filter(examples, & &1.showcase)

    duplicate_values(examples, & &1.name, "example name") ++
      duplicate_values(examples, & &1.module, "runner module") ++
      duplicate_values(examples, & &1.agent, "agent module") ++
      duplicate_values(showcased, & &1.showcase.route, "showcase route") ++
      duplicate_values(showcased, & &1.showcase.live_view, "showcase LiveView") ++
      duplicate_values(showcased, & &1.showcase.view, "showcase AgentView")
  end

  defp duplicate_values(examples, mapper, label) do
    examples
    |> Enum.group_by(mapper)
    |> Enum.filter(fn {_value, matches} -> length(matches) > 1 end)
    |> Enum.map(fn {value, _matches} -> "duplicate #{label}: #{inspect(value)}" end)
  end

  defp static_gate(all_examples, selected, root) do
    errors =
      production_boundary_errors(root) ++
        Enum.flat_map(selected, &example_file_errors(&1, root)) ++
        showcase_file_errors(selected, root) ++
        global_case_errors(all_examples)

    gate(:surface_contracts, :infrastructure, :selected_examples, errors)
  end

  defp production_boundary_errors(root) do
    if Path.expand(File.cwd!()) == root do
      Mix.Project.config()
      |> Keyword.get(:elixirc_paths, ["lib"])
      |> Enum.filter(fn path ->
        String.starts_with?(path, "examples") and
          not (Mix.env() == :test and path == "examples/_support")
      end)
      |> Enum.map(&"root production build compiles example path: #{&1}")
    else
      []
    end
  end

  defp example_file_errors(example, root) do
    required = [
      {"README", example.readme, :file},
      {"agent", Path.join(example.lib_dir, "agent.ex"), :file},
      {"example runner", Path.join(example.root, "example.exs"), :file},
      {"library folder", example.lib_dir, :dir},
      {"Livebook", example.livebook, :file},
      {"support folder", example.support_dir, :dir}
    ]

    path_errors =
      Enum.flat_map(required, fn {label, path, type} ->
        valid? = if type == :dir, do: File.dir?(path), else: File.regular?(path)
        if valid?, do: [], else: ["#{example.name}: missing #{label} at #{Path.relative_to(path, root)}"]
      end)

    path_errors ++
      maybe_error(Catalog.source_files(example) == [], "#{example.name}: library folder has no .ex files") ++
      maybe_error(Catalog.support_files(example) == [], "#{example.name}: support folder has no .ex or .exs files") ++
      maybe_error(example.test_files == [], "#{example.name}: no proof test files were found") ++
      namespace_errors(example)
  end

  defp namespace_errors(example) do
    expected = "Elixir.JidokaExamples.#{Macro.camelize(example.dir)}"

    [example.module, example.agent]
    |> Enum.reject(&(Atom.to_string(&1) |> String.starts_with?(expected)))
    |> Enum.map(&"#{example.name}: module must use the #{expected} namespace: #{inspect(&1)}")
  end

  defp showcase_file_errors(examples, root) do
    if File.dir?(Path.join(root, "showcase")) do
      examples
      |> Enum.filter(& &1.showcase)
      |> Enum.flat_map(fn example ->
        (example.showcase.sources ++ example.showcase.tests)
        |> Enum.reject(&(root |> Path.join(&1) |> File.regular?()))
        |> Enum.map(&"#{example.name}: missing showcase file #{&1}")
      end)
    else
      []
    end
  end

  defp global_case_errors(examples) do
    examples
    |> Enum.flat_map(fn example ->
      Enum.map(Catalog.case_declarations(example), fn {scenario, scenario_case} ->
        {example.name, scenario.id, scenario_case.id}
      end)
    end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(fn {key, _count} -> "duplicate proof case identity: #{inspect(key)}" end)
  end

  defp publication_gate(%ProofReport{} = report, examples, opts, root) do
    if report.selection.mode == :all and report.status == :ok do
      path = Path.join(root, "examples/PROVEN_FEATURES.md")
      generated = Reporter.document(report, examples)

      with {:ok, content} <- File.read(path),
           {:ok, candidate} <- Reporter.candidate(content, generated) do
        cond do
          Keyword.get(opts, :update_proof, false) ->
            case Reporter.publish(path, candidate) do
              :ok -> append_gate(report, publication_result(:ok, "Updated examples/PROVEN_FEATURES.md."))
              {:error, reason} -> append_gate(report, publication_result(:error, inspect(reason)))
            end

          candidate == content ->
            append_gate(report, publication_result(:ok, nil))

          true ->
            append_gate(
              report,
              publication_result(
                :error,
                "Verified coverage is not current. Run mix jidoka.examples.check --update-proof."
              )
            )
        end
      else
        {:error, reason} -> append_gate(report, publication_result(:error, format_file_error(reason)))
      end
    else
      report
    end
  end

  defp add_changed_paths(opts, root) do
    case Keyword.get(opts, :changed) do
      nil ->
        {:ok, opts}

      ref ->
        case changed_paths(ref, root) do
          {:ok, paths} -> {:ok, Keyword.put(opts, :changed_paths, paths)}
          {:error, message} -> {:error, message}
        end
    end
  end

  defp changed_paths(ref, root) do
    commands = [
      ["diff", "--name-status", "-z", "#{ref}...HEAD"],
      ["diff", "--name-status", "-z"],
      ["diff", "--name-status", "-z", "--cached"],
      ["ls-files", "--others", "--exclude-standard", "-z"]
    ]

    Enum.reduce_while(commands, {:ok, []}, fn args, {:ok, changes} ->
      case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
        {output, 0} -> {:cont, {:ok, changes ++ parse_changes(args, output)}}
        {output, _status} -> {:halt, {:error, "Cannot inspect changed files: #{String.trim(output)}"}}
      end
    end)
    |> then(fn
      {:ok, changes} -> {:ok, Enum.uniq(changes)}
      error -> error
    end)
  end

  defp parse_changes(["ls-files" | _args], output) do
    output
    |> String.split(<<0>>, trim: true)
    |> Enum.map(&%{status: "?", paths: [&1]})
  end

  defp parse_changes(_args, output), do: parse_name_status(String.split(output, <<0>>, trim: true), [])

  defp parse_name_status([], changes), do: Enum.reverse(changes)

  defp parse_name_status([status, old_path, new_path | rest], changes)
       when binary_part(status, 0, 1) in ["R", "C"] do
    parse_name_status(rest, [%{status: status, paths: [old_path, new_path]} | changes])
  end

  defp parse_name_status([status, path | rest], changes) do
    parse_name_status(rest, [%{status: status, paths: [path]} | changes])
  end

  defp parse_name_status(_malformed, changes), do: Enum.reverse(changes)

  defp gate(id, scope, subject, []), do: result_gate(id, scope, subject, :ok, nil)
  defp gate(id, scope, subject, errors), do: result_gate(id, scope, subject, :error, Enum.join(errors, "\n"))

  defp result_gate(id, scope, subject, status, message) do
    %GateResult{
      command: nil,
      duration_ms: 0,
      id: id,
      message: message,
      output: nil,
      scope: scope,
      status: status,
      subject: subject
    }
  end

  defp skipped_gate(planned, message) do
    %GateResult{
      command: planned.command,
      duration_ms: 0,
      id: planned.id,
      message: message,
      output: nil,
      scope: planned.scope,
      status: :skipped,
      subject: planned.subject
    }
  end

  defp publication_result(status, message) do
    result_gate(:proof_document, :documentation, :published_coverage, status, message)
  end

  defp append_gate(%ProofReport{} = report, gate) do
    status = if report.status == :ok and gate.status == :ok, do: :ok, else: :error
    %ProofReport{report | gates: report.gates ++ [gate], status: status}
  end

  defp failed_report(message, opts) do
    %ProofReport{
      cases: [],
      coverage: %{},
      gates: [result_gate(:setup, :infrastructure, :checker, :error, message)],
      schema_version: 1,
      selection: %{
        mode: selection_mode(opts),
        examples: [],
        reasons: []
      },
      status: :error
    }
  end

  defp selection_mode(opts) do
    cond do
      Keyword.get(opts, :example) -> :example
      Keyword.get(opts, :changed) -> :changed
      true -> :all
    end
  end

  defp maybe_error(true, message), do: [message]
  defp maybe_error(false, _message), do: []
  defp catalog_error(error), do: "#{error.path}: #{error.message}"
  defp format_file_error(reason) when is_atom(reason), do: :file.format_error(reason) |> to_string()
  defp format_file_error(reason), do: inspect(reason)

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.trim_leading(":")
    |> String.replace("-", "_")
  end
end
