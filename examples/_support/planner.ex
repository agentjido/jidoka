defmodule JidokaExamples.Planner do
  @moduledoc false

  alias JidokaExamples.{Manifest, Timeouts}

  @proof_infrastructure [
    "examples/_support/",
    "lib/",
    "test/support/"
  ]
  @global_paths ["config/", "mix.exs", "mix.lock"]

  @spec plan([Manifest.t()], keyword(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def plan(examples, opts, root) do
    with {:ok, selection} <- select(examples, opts) do
      gates = build_gates(selection, root, Keyword.get(opts, :verbose, false))
      {:ok, Map.put(selection, :gates, gates)}
    end
  end

  defp select(examples, opts) do
    cond do
      name = Keyword.get(opts, :example) -> select_example(examples, name)
      Keyword.has_key?(opts, :changed_paths) -> select_changed(examples, opts[:changed_paths])
      true -> {:ok, full_selection(examples)}
    end
  end

  defp select_example(examples, name) do
    normalized = normalize_name(name)

    case Enum.find(examples, &(Atom.to_string(&1.name) == normalized)) do
      nil ->
        names = examples |> Enum.map(& &1.name) |> Enum.join(", ")
        {:error, "Unknown example #{inspect(name)}. Available: #{names}"}

      example ->
        {:ok,
         %{
           mode: :example,
           examples: [example],
           guides: [],
           global?: false,
           reasons: [%{subject: example.name, reason: "selected by --example"}]
         }}
    end
  end

  defp select_changed(examples, changes) do
    paths = changes |> Enum.flat_map(& &1.paths) |> Enum.uniq() |> Enum.sort()
    deleted_example? = Enum.any?(changes, &deleted_example?/1)
    deleted_guide? = Enum.any?(changes, &deleted_guide?/1)
    all_examples? = deleted_example? or Enum.any?(paths, &all_examples_path?/1)
    shared_showcase? = Enum.any?(paths, &shared_showcase_path?(&1, examples))

    selected =
      if all_examples? do
        examples
      else
        Enum.filter(examples, fn example ->
          (shared_showcase? and not is_nil(example.showcase)) or
            Enum.any?(paths, &example_path?(&1, example)) or
            (not is_nil(example.showcase) and
               Enum.any?(paths, &(&1 in (example.showcase.sources ++ example.showcase.tests))))
        end)
      end

    guides = Enum.filter(paths, &guide_path?/1)

    global? =
      deleted_example? or deleted_guide? or shared_showcase? or Enum.any?(paths, &global_path?/1)

    example_reasons =
      Enum.map(selected, fn example ->
        cause = Enum.find(paths, &impact_example?(&1, example)) || "shared proof infrastructure"
        %{subject: example.name, reason: "affected by #{cause}"}
      end)

    guide_reasons = Enum.map(guides, &%{subject: &1, reason: "changed guide"})

    global_reasons =
      if global? do
        cause = Enum.find(paths, &global_path?/1) || List.first(paths) || "deleted proof surface"
        [%{subject: :global, reason: "global gates affected by #{cause}"}]
      else
        []
      end

    reasons = example_reasons ++ guide_reasons ++ global_reasons

    {:ok,
     %{
       mode: :changed,
       examples: selected,
       guides: guides,
       global?: global?,
       reasons: reasons
     }}
  end

  defp full_selection(examples) do
    %{
      mode: :all,
      examples: examples,
      guides: :all,
      global?: true,
      reasons: []
    }
  end

  defp build_gates(selection, root, verbose?) do
    examples = selection.examples
    guide_paths = selected_guides(selection.guides, root)
    showcased = Enum.filter(examples, & &1.showcase)

    work_gates =
      Enum.map(examples, &example_gate(&1, root, verbose?)) ++
        Enum.map(examples, &livebook_gate(&1, root)) ++
        Enum.map(guide_paths, &guide_gate(&1, root)) ++
        showcase_gates(showcased, selection, root, verbose?) ++
        documentation_gates(selection, root)

    if work_gates == [] do
      []
    else
      [warm_gate(root) | work_gates]
    end
  end

  defp warm_gate(root) do
    command_gate(
      :root_compile,
      0,
      :infrastructure,
      :root,
      root,
      ["mix", "compile", "--warnings-as-errors"],
      Timeouts.fetch!(:compile),
      env: [{"MIX_ENV", "test"}]
    )
  end

  defp example_gate(example, root, verbose?) do
    args =
      ["mix", "test", "--no-compile", "--no-deps-check"] ++
        Enum.map(example.test_files, &Path.relative_to(&1, root)) ++
        ["--formatter", "ExUnit.CLIFormatter", "--formatter", "JidokaExamples.ExUnitFormatter"] ++
        if(verbose?, do: ["--trace"], else: [])

    command_gate(
      gate_id(example.name, :exunit),
      1,
      :scenario,
      example.name,
      root,
      args,
      Timeouts.fetch!(:example),
      artifact: :exunit
    )
  end

  defp livebook_gate(example, root) do
    command_gate(
      gate_id(example.name, :livebook),
      2,
      :scenario,
      example.name,
      root,
      [
        "mix",
        "run",
        "--no-compile",
        "--no-deps-check",
        "examples/_support/check_livebook.exs",
        "--",
        "--project",
        Path.relative_to(example.livebook, root)
      ],
      Timeouts.fetch!(:livebook)
    )
  end

  defp guide_gate(path, root) do
    id = path |> Path.basename(".livemd") |> then(&String.to_atom("guide_#{&1}_livebook"))

    command_gate(
      id,
      2,
      :guide,
      Path.relative_to(path, root),
      root,
      [
        "mix",
        "run",
        "--no-compile",
        "--no-deps-check",
        "examples/_support/check_livebook.exs",
        "--",
        "--project",
        Path.relative_to(path, root)
      ],
      Timeouts.fetch!(:livebook)
    )
  end

  defp showcase_gates([], _selection, _root, _verbose?), do: []

  defp showcase_gates(showcased, selection, root, verbose?) do
    showcase_root = Path.join(root, "showcase")

    compile =
      command_gate(
        :showcase_compile,
        3,
        :showcase,
        :showcase,
        showcase_root,
        ["mix", "compile", "--warnings-as-errors"],
        Timeouts.fetch!(:showcase_compile),
        env: [{"MIX_ENV", "test"}]
      )

    {test_args, timeout} =
      if selection.mode == :all or selection.global? do
        {[], Timeouts.fetch!(:showcase_full)}
      else
        paths = showcased |> Enum.flat_map(& &1.showcase.tests) |> Enum.uniq() |> Enum.sort()
        {Enum.map(paths, &Path.relative_to(&1, "showcase")), Timeouts.fetch!(:showcase_focused)}
      end

    args =
      ["mix", "test", "--no-compile", "--no-deps-check"] ++
        test_args ++ if(verbose?, do: ["--trace"], else: [])

    tests =
      command_gate(
        :showcase_test,
        4,
        :showcase,
        :showcase,
        showcase_root,
        args,
        timeout
      )

    [compile, tests]
  end

  defp documentation_gates(%{mode: :all}, root), do: [documentation_gate(root)]
  defp documentation_gates(%{global?: true}, root), do: [documentation_gate(root)]
  defp documentation_gates(_selection, _root), do: []

  defp documentation_gate(root) do
    command_gate(
      :documentation,
      5,
      :documentation,
      :ex_doc,
      root,
      ["mix", "docs"],
      Timeouts.fetch!(:documentation)
    )
  end

  defp command_gate(id, stage, scope, subject, cd, command, timeout_ms, extra \\ []) do
    %{
      id: id,
      stage: stage,
      scope: scope,
      subject: subject,
      cd: cd,
      command: command,
      timeout_ms: timeout_ms
    }
    |> Map.merge(Map.new(extra))
  end

  defp selected_guides(:all, root), do: Path.wildcard(Path.join(root, "guides/livebooks/*.livemd"))

  defp selected_guides(paths, root) do
    paths
    |> Enum.map(&Path.join(root, &1))
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  defp all_examples_path?(path) do
    Enum.any?(@proof_infrastructure ++ @global_paths, &path_matches?(path, &1))
  end

  defp global_path?(path) do
    Enum.any?(@global_paths, &path_matches?(path, &1)) or
      path == "examples/README.md" or
      (String.starts_with?(path, "showcase/") and not String.contains?(path, "support_agent")) or
      root_document?(path)
  end

  defp impact_example?(path, example) do
    all_examples_path?(path) or example_path?(path, example) or
      (not is_nil(example.showcase) and path in (example.showcase.sources ++ example.showcase.tests))
  end

  defp example_path?(path, example), do: String.starts_with?(path, "examples/#{example.dir}/")
  defp guide_path?(path), do: String.starts_with?(path, "guides/livebooks/") and String.ends_with?(path, ".livemd")

  defp root_document?(path) do
    Path.dirname(path) == "." and Path.extname(path) in [".md", ".livemd"]
  end

  defp deleted_example?(%{status: "D" <> _rest, paths: paths}) do
    Enum.any?(paths, &scenario_path?/1)
  end

  defp deleted_example?(_change), do: false

  defp deleted_guide?(%{status: "D" <> _rest, paths: paths}) do
    Enum.any?(paths, &guide_path?/1)
  end

  defp deleted_guide?(_change), do: false

  defp scenario_path?("examples/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [dir, _path] -> dir != "_support"
      _other -> false
    end
  end

  defp scenario_path?(_path), do: false

  defp shared_showcase_path?("showcase/" <> _rest = path, examples) do
    not Enum.any?(examples, fn example ->
      not is_nil(example.showcase) and
        path in (example.showcase.sources ++ example.showcase.tests)
    end)
  end

  defp shared_showcase_path?(_path, _examples), do: false

  defp path_matches?(path, prefix) do
    path == prefix or (String.ends_with?(prefix, "/") and String.starts_with?(path, prefix))
  end

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.trim_leading(":")
    |> String.replace("-", "_")
  end

  defp gate_id(example, suffix), do: String.to_atom("#{example}_#{suffix}")
end
