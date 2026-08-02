defmodule Jidoka.Architecture.BoundariesTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @core_contract_globs [
    "lib/jidoka/agent/spec.ex",
    "lib/jidoka/agent/spec/**/*.ex",
    "lib/jidoka/effect/**/*.ex",
    "lib/jidoka/turn/{cursor,plan,request,result,state,transition}.ex",
    "lib/jidoka/turn/state/**/*.ex",
    "lib/jidoka/session/{data,lease,lineage,transitions}.ex",
    "lib/jidoka/review/{interrupt,policy,request,response}.ex",
    "lib/jidoka/memory/{entry,recall_request,recall_result,write_request,write_result}.ex",
    "lib/jidoka/workflow/{definition,spec,step,snapshot,run,run_event,retry_policy}.ex",
    "lib/jidoka/workflow/definition/**/*.ex"
  ]

  @outward_namespaces [
    "Jidoka.Adapter",
    "Jidoka.Harness",
    "Jidoka.Projection",
    "Jidoka.Runtime",
    "Jido",
    "ReqLLM",
    "Runic",
    "AshJido"
  ]

  test "core contracts do not depend on execution, adapters, or presentation" do
    violations =
      @core_contract_globs
      |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
      |> Enum.uniq()
      |> Enum.flat_map(fn file ->
        file
        |> module_references()
        |> Enum.filter(&outward_reference?/1)
        |> Enum.map(&{relative(file), &1})
      end)

    assert violations == [], format_violations("outward core dependencies", violations)
  end

  test "runtime code has no direct third-party framework calls" do
    violations =
      Path.wildcard(Path.join(@root, "lib/jidoka/runtime/**/*.ex"))
      |> Enum.flat_map(fn file ->
        file
        |> module_references()
        |> Enum.filter(&external_framework?/1)
        |> Enum.map(&{relative(file), &1})
      end)

    assert violations == [], format_violations("runtime adapter bypasses", violations)
  end

  test "internal production modules do not call the root facade" do
    allowed_edges = [
      "lib/jidoka/agent_view.ex"
    ]

    violations =
      Path.wildcard(Path.join(@root, "lib/jidoka/**/*.ex"))
      |> Enum.reject(fn file ->
        relative(file) in allowed_edges or relative(file) =~ ~r{^lib/jidoka/kino(?:/|\.ex$)}
      end)
      |> Enum.flat_map(fn file ->
        file
        |> root_facade_dependencies()
        |> Enum.map(&{relative(file), &1})
      end)

    assert violations == [], format_violations("root facade calls", violations)
  end

  test "adapter files use the adapter module namespace" do
    violations =
      Path.wildcard(Path.join(@root, "lib/jidoka/adapter/**/*.ex"))
      |> Enum.flat_map(fn file ->
        modules = declared_modules(file)

        if modules != [] and Enum.all?(modules, &String.starts_with?(&1, "Jidoka.Adapter.")) do
          []
        else
          [{relative(file), Enum.join(modules, ", ")}]
        end
      end)

    assert violations == [], format_violations("adapter namespace mismatches", violations)
  end

  test "Kino modules stay behind the development and test compile guard" do
    violations =
      [Path.join(@root, "lib/jidoka/kino.ex") | Path.wildcard(Path.join(@root, "lib/jidoka/kino/**/*.ex"))]
      |> Enum.reject(fn file ->
        file
        |> File.read!()
        |> String.trim_leading()
        |> String.starts_with?("if Mix.env() in [:dev, :test] do")
      end)
      |> Enum.map(&relative/1)

    assert violations == [], "unguarded Kino sources: #{inspect(violations)}"
  end

  defp module_references(file) do
    file
    |> quoted!()
    |> Macro.prewalk(MapSet.new(), fn
      {:alias, _meta, [{{:., _dot_meta, [{:__aliases__, _base_meta, base}, :{}]}, _group_meta, children}]} = node,
      references ->
        expanded =
          Enum.reduce(children, references, fn
            {:__aliases__, _child_meta, child}, acc ->
              put_alias_reference(acc, base ++ child)

            _child, acc ->
              acc
          end)

        {node, expanded}

      {:__aliases__, _meta, parts} = node, references when is_list(parts) ->
        {node, put_alias_reference(references, parts)}

      node, references ->
        {node, references}
    end)
    |> elem(1)
    |> MapSet.to_list()
  end

  defp put_alias_reference(references, parts) do
    if Enum.all?(parts, &is_atom/1) do
      MapSet.put(references, Enum.join(parts, "."))
    else
      references
    end
  end

  defp root_facade_dependencies(file) do
    calls = root_facade_calls(file)

    if "Jidoka" in module_references(file) do
      Enum.uniq(["Jidoka alias/reference" | calls])
    else
      calls
    end
  end

  defp root_facade_calls(file) do
    file
    |> quoted!()
    |> Macro.prewalk(MapSet.new(), fn
      {{:., _dot_meta, [{:__aliases__, _alias_meta, [:Jidoka]}, function]}, _call_meta, _args} = node, calls
      when is_atom(function) ->
        {node, MapSet.put(calls, "Jidoka.#{function}")}

      node, calls ->
        {node, calls}
    end)
    |> elem(1)
    |> MapSet.to_list()
  end

  defp declared_modules(file) do
    file
    |> quoted!()
    |> Macro.prewalk([], fn
      {:defmodule, _meta, [{:__aliases__, _alias_meta, parts} | _rest]} = node, modules ->
        {node, [Enum.join(parts, ".") | modules]}

      node, modules ->
        {node, modules}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp quoted!(file) do
    file
    |> File.read!()
    |> Code.string_to_quoted!(file: file)
  end

  defp outward_reference?(reference), do: Enum.any?(@outward_namespaces, &namespace?(reference, &1))

  defp external_framework?(reference) do
    Enum.any?(["Jido", "ReqLLM", "Runic", "AshJido"], &namespace?(reference, &1))
  end

  defp namespace?(reference, namespace),
    do: reference == namespace or String.starts_with?(reference, namespace <> ".")

  defp relative(file), do: Path.relative_to(file, @root)

  defp format_violations(label, violations) do
    details = Enum.map_join(violations, "\n", fn {file, reference} -> "  #{file}: #{reference}" end)
    "#{label}:\n#{details}"
  end
end
