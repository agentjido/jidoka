defmodule Jidoka.CheckDocs do
  @moduledoc false

  @markdown_patterns [
    "README.md",
    "CONTRIBUTING.md",
    "usage-rules.md",
    "guides/**/*.md",
    "examples/**/*.md",
    "audits/public-api/*.md"
  ]

  @executable_doc_patterns [
    "guides/**/*.livemd",
    "examples/**/*.livemd",
    "examples/**/*.ex",
    "examples/**/*.exs"
  ]

  @start_here [
    "guides/getting-started.md",
    "guides/documentation-overview.md",
    "guides/core-concepts.md"
  ]

  @beginner_docs [
    "README.md",
    "guides/getting-started.md",
    "guides/tools-and-operations.md",
    "guides/testing-and-evals.md"
  ]

  @internal_guides [
    "guides/architecture-boundaries.md",
    "guides/runtime-and-harness.md",
    "guides/runic-spine-internals.md",
    "guides/turn-runner-and-effect-interpreter.md",
    "guides/runtime-capabilities-internals.md",
    "guides/projection-internals.md",
    "guides/contributor-testing.md"
  ]

  @example_sections [
    "Purpose",
    "Features",
    "Read It In This Order",
    "Run It",
    "Expected Result",
    "Next Guide"
  ]

  @hidden_module_link ~r/\]\(`Jidoka\.(?:Adapter|Runtime|Harness|Projection|(?:Turn|Session|Review)\.Execution)[^`]*`\)/
  @internal_invocation ~r/Jidoka\.(?:Harness|Turn\.Execution|Session\.Execution|Review\.Execution|Runtime\.(?:TurnRunner|EffectInterpreter)|Projection)\.[a-z_][a-z0-9_!?]*\(/
  @generated_invocation ~r/(?<![A-Za-z0-9_.])(?!Jidoka(?:\.|$))[A-Z][A-Za-z0-9_.]*\.(?:chat|run_turn)\(/

  def run do
    markdown_files = files(@markdown_patterns)
    executable_docs = files(@executable_doc_patterns)
    all_docs = Enum.uniq(markdown_files ++ executable_docs)

    failures =
      []
      |> Kernel.++(link_failures(markdown_files))
      |> Kernel.++(version_failures(markdown_files))
      |> Kernel.++(credential_failures())
      |> Kernel.++(start_here_failures())
      |> Kernel.++(canonical_path_failures(all_docs))
      |> Kernel.++(example_section_failures())

    if failures == [] do
      IO.puts("PASS documentation alignment checks (#{length(all_docs)} files)")
    else
      Enum.each(failures, &IO.puts(:stderr, "FAIL #{&1}"))
      raise "documentation alignment failed with #{length(failures)} error(s)"
    end
  end

  defp files(patterns) do
    patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp link_failures(files) do
    Enum.flat_map(files, fn file ->
      content = File.read!(file)

      ~r/!?\[[^\]\n]*\]\(([^)\n]+)\)/
      |> Regex.scan(content, return: :index, capture: :all_but_first)
      |> Enum.flat_map(fn [{start, length}] ->
        target = binary_part(content, start, length) |> String.trim() |> String.trim("<>")

        case local_link_error(file, target) do
          nil -> []
          reason -> [location(file, content, start) <> " #{reason}"]
        end
      end)
    end)
  end

  defp local_link_error(_file, ""), do: nil
  defp local_link_error(_file, "#" <> _anchor), do: nil
  defp local_link_error(_file, "`" <> _module), do: nil

  defp local_link_error(file, target) do
    uri = URI.parse(target)

    if uri.scheme in ["http", "https", "mailto", "tel"] do
      nil
    else
      local_link_error(uri, target, file)
    end
  end

  defp local_link_error(%URI{path: path, fragment: fragment}, target, file) do
    path = if path in [nil, ""], do: file, else: Path.expand(URI.decode(path), Path.dirname(file))

    cond do
      not File.exists?(path) ->
        "links to missing local target #{inspect(target)}"

      fragment not in [nil, ""] and File.regular?(path) and not anchor_exists?(path, fragment) ->
        "links to missing anchor #{inspect(fragment)} in #{path}"

      true ->
        nil
    end
  end

  defp anchor_exists?(path, fragment) do
    anchors =
      path
      |> File.read!()
      |> then(&Regex.scan(~r/^[#]{1,6}\s+(.+)$/m, &1, capture: :all_but_first))
      |> Enum.map(fn [heading] -> heading_anchor(heading) end)

    URI.decode(fragment) in anchors
  end

  defp heading_anchor(heading) do
    heading
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s-]/u, "")
    |> String.trim()
    |> String.replace(~r/\s+/, "-")
  end

  defp version_failures(files) do
    mix = File.read!("mix.exs")
    [version] = Regex.run(~r/@version\s+"([^"]+)"/, mix, capture: :all_but_first)

    patterns = [
      ~r/jidoka@([0-9][0-9A-Za-z.-]+)/,
      ~r/\{:jidoka,\s*"~>\s*([^"]+)"\}/
    ]

    Enum.flat_map(files, fn file ->
      content = File.read!(file)

      Enum.flat_map(patterns, fn pattern ->
        pattern
        |> Regex.scan(content, return: :index, capture: :all_but_first)
        |> Enum.flat_map(fn [{start, length}] ->
          documented = binary_part(content, start, length)

          if documented == version do
            []
          else
            [
              location(file, content, start) <>
                " uses Jidoka version #{inspect(documented)}; expected #{inspect(version)}"
            ]
          end
        end)
      end)
    end)
  end

  defp credential_failures do
    required = [
      "Jidoka does not implement dotenv loading.",
      "ReqLLM is a Jidoka runtime dependency, and it loads `.env` from the current working directory by default",
      "config :req_llm, load_dotenv: false"
    ]

    Enum.flat_map(["README.md", "guides/getting-started.md"], fn file ->
      content = file |> File.read!() |> String.replace(~r/\s+/, " ")

      Enum.flat_map(required, fn statement ->
        if String.contains?(content, statement),
          do: [],
          else: ["#{file} is missing the shared credential statement #{inspect(statement)}"]
      end)
    end)
  end

  defp start_here_failures do
    Enum.flat_map(@start_here, fn file ->
      content = File.read!(file)

      @hidden_module_link
      |> Regex.scan(content, return: :index)
      |> Enum.map(fn [{start, _length}] ->
        location(file, content, start) <> " links to an internal module from Start Here"
      end)
    end)
  end

  defp canonical_path_failures(all_docs) do
    generated = pattern_failures(@beginner_docs, @generated_invocation, "uses a generated agent invocation")

    old_prompt =
      pattern_failures(all_docs, ~r/preflight\.prompt\.tool_definitions/, "uses the old preflight tool field")

    application_docs = Enum.reject(all_docs, &(&1 in @internal_guides))

    internal =
      pattern_failures(
        application_docs,
        @internal_invocation,
        "invokes an internal execution module from application documentation"
      )

    generated ++ old_prompt ++ internal
  end

  defp pattern_failures(files, pattern, message) do
    Enum.flat_map(files, fn file ->
      content = File.read!(file)

      pattern
      |> Regex.scan(content, return: :index)
      |> Enum.map(fn [{start, _length} | _captures] ->
        location(file, content, start) <> " #{message}"
      end)
    end)
  end

  defp example_section_failures do
    "examples/*/README.md"
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      content = File.read!(file)

      Enum.flat_map(@example_sections, fn section ->
        if String.contains?(content, "## #{section}"),
          do: [],
          else: ["#{file} is missing the required section #{inspect(section)}"]
      end)
    end)
  end

  defp location(file, content, byte_offset) do
    line = content |> binary_part(0, byte_offset) |> :binary.matches("\n") |> length()
    "#{file}:#{line + 1}"
  end
end

Jidoka.CheckDocs.run()
