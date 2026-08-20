defmodule Jidoka.Architecture.BoundariesTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @core_contract_globs [
    "lib/jidoka/agent/{message,state}.ex",
    "lib/jidoka/agent/spec.ex",
    "lib/jidoka/agent/spec/**/*.ex",
    "lib/jidoka/{cancellation,content_part,context,event,snapshot,usage}.ex",
    "lib/jidoka/cancellation/**/*.ex",
    "lib/jidoka/effect/**/*.ex",
    "lib/jidoka/turn/{cursor,plan,request,result,state,transition}.ex",
    "lib/jidoka/turn/state/**/*.ex",
    "lib/jidoka/session/{data,lease,lineage,transitions}.ex",
    "lib/jidoka/review/{approval,interrupt,policy,request,response}.ex",
    "lib/jidoka/memory/{entry,recall_request,recall_result,write_request,write_result}.ex",
    "lib/jidoka/workflow/{definition,ref,spec,step,snapshot,run,run_event,retry_policy,schedule}.ex",
    "lib/jidoka/workflow/definition/**/*.ex",
    "lib/jidoka/workflow/schedule/**/*.ex"
  ]

  @runtime_shell_globs [
    "lib/jidoka/memory/runtime.ex",
    "lib/jidoka/runtime/**/*.ex",
    "lib/jidoka/workflow/runtime/**/*.ex"
  ]

  @pure_transition_files [
    "lib/jidoka/session/transitions.ex",
    "lib/jidoka/turn/transition.ex"
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

  @normalized_final_schema_files [
    "lib/jidoka/chat/request.ex",
    "lib/jidoka/stream.ex",
    "lib/jidoka/operation/source/catalog.ex",
    "lib/jidoka/operation/source/handoff.ex",
    "lib/jidoka/operation/source/local.ex",
    "lib/jidoka/operation/source/mcp.ex",
    "lib/jidoka/operation/source/subagent.ex",
    "lib/jidoka/operation/source/workflow.ex",
    "lib/jidoka/workflow/lua/plan/spec.ex",
    "lib/jidoka/workflow/lua/policy.ex"
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

  test "runtime shell does not depend on adapters, projections, or external frameworks" do
    violations =
      @runtime_shell_globs
      |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
      |> Enum.uniq()
      |> Enum.flat_map(fn file ->
        file
        |> module_references()
        |> Enum.filter(&runtime_outward_reference?/1)
        |> Enum.map(&{relative(file), &1})
      end)

    assert violations == [], format_violations("outward runtime dependencies", violations)
  end

  test "pure transitions do not read clocks or start effects" do
    forbidden = ~r/\b(?:System\.(?:system_time|monotonic_time)|DateTime\.utc_now|Task\.|GenServer\.|Process\.)/

    violations =
      Enum.flat_map(@pure_transition_files, fn relative_file ->
        relative_file
        |> then(&Path.join(@root, &1))
        |> File.stream!()
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, line_number} ->
          if Regex.match?(forbidden, line), do: [{relative_file, line_number}], else: []
        end)
      end)

    assert violations == [], format_violations("effects in pure transitions", violations)
  end

  test "internal production modules do not call the root facade" do
    violations =
      Path.wildcard(Path.join(@root, "lib/jidoka/**/*.ex"))
      |> Enum.reject(fn file ->
        relative(file) =~ ~r{^lib/jidoka/kino(?:/|\.ex$)}
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

  test "Zoi-backed structs derive their type and layout from the final schema" do
    violations =
      Path.wildcard(Path.join(@root, "lib/**/*.ex"))
      |> Enum.flat_map(fn file ->
        source = File.read!(file)
        schema_count = source_count(source, ~r/@schema\s+Zoi\.struct\(/)

        if schema_count == 0 do
          []
        else
          generated =
            source_count(
              source,
              ~r/@(?:type|opaque) t\s*::\s*unquote\(Zoi\.type_spec\(@schema\)\)/
            )

          enforce_keys = source_count(source, ~r/@enforce_keys\s+Zoi\.Struct\.enforce_keys\(@schema\)/)
          struct_fields = source_count(source, ~r/defstruct\s+Zoi\.Struct\.struct_fields\(@schema\)/)

          if generated == schema_count and enforce_keys == schema_count and struct_fields == schema_count do
            []
          else
            [
              {relative(file),
               "schemas=#{schema_count}, generated_types=#{generated}, enforce_keys=#{enforce_keys}, struct_fields=#{struct_fields}"}
            ]
          end
        end
      end)

    assert violations == [], format_violations("Zoi schema ownership mismatches", violations)
  end

  test "normalized final-schema constructors finish through schema parsing" do
    violations =
      Enum.flat_map(@normalized_final_schema_files, fn relative_file ->
        source = @root |> Path.join(relative_file) |> File.read!()

        if String.contains?(source, "Schema.parse(@schema") or
             String.contains?(source, "Schema.parse!(@schema") do
          []
        else
          [{relative_file, "missing final Schema.parse/2 or Schema.parse!/3 step"}]
        end
      end)

    assert violations == [], format_violations("normalized schema constructor bypasses", violations)
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

  defp runtime_outward_reference?(reference) do
    Enum.any?(
      ["Jidoka.Adapter", "Jidoka.Projection", "Jido", "ReqLLM", "Runic", "AshJido"],
      &namespace?(reference, &1)
    )
  end

  defp namespace?(reference, namespace),
    do: reference == namespace or String.starts_with?(reference, namespace <> ".")

  defp relative(file), do: Path.relative_to(file, @root)

  defp format_violations(label, violations) do
    details = Enum.map_join(violations, "\n", fn {file, reference} -> "  #{file}: #{reference}" end)
    "#{label}:\n#{details}"
  end

  defp source_count(source, pattern), do: pattern |> Regex.scan(source) |> length()
end
