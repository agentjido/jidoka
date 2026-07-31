defmodule JidokaExamples.Reporter do
  @moduledoc false

  alias JidokaExamples.{CaseResult, GateResult, ProofReport}

  @schema_version 1

  @spec build(map(), [GateResult.t()], map()) :: ProofReport.t()
  def build(selection, gates, artifacts) do
    {cases, reconciliation_gate} = reconcile(selection.examples, artifacts)
    gates = gates ++ [reconciliation_gate]
    failed? = Enum.any?(gates, &(&1.status == :error)) or Enum.any?(cases, &(&1.status != :passed))

    %ProofReport{
      cases: cases,
      coverage: coverage(cases),
      gates: gates,
      schema_version: @schema_version,
      selection: public_selection(selection),
      status: if(failed?, do: :error, else: :ok)
    }
  end

  @spec document(ProofReport.t(), [JidokaExamples.Manifest.t()]) :: String.t()
  def document(report, examples) do
    manifest_by_name = Map.new(examples, &{&1.name, &1})

    rows =
      for result <- report.cases,
          result.status == :passed,
          capability <- result.proves,
          manifest = Map.fetch!(manifest_by_name, result.example) do
        [
          label(capability),
          "[#{manifest.title}](../examples/#{manifest.dir}/README.md)",
          label(result.scenario),
          label(result.case_id),
          "[ExUnit](../#{result.test.file})",
          "[Livebook](../examples/#{manifest.dir}/#{manifest.dir}.livemd)",
          showcase_label(manifest.showcase)
        ]
      end

    rows = Enum.sort_by(rows, &{Enum.at(&1, 0), Enum.at(&1, 1), Enum.at(&1, 2), Enum.at(&1, 3)})

    [
      "# Proven Features",
      "",
      "This local report comes from the latest complete `mix jidoka.examples.check` run.",
      "It is generated proof output and is not part of the public package.",
      "",
      "## Verified Capability Coverage",
      "",
      "This table comes only from passed ExUnit proof cases in a complete check.",
      "Livebook and showcase checks verify their surfaces. They do not add capability coverage.",
      "",
      markdown_row(["Capability", "Example", "Scenario", "Case", "Test", "Livebook", "Showcase"]),
      markdown_row(["---", "---", "---", "---", "---", "---", "---"])
      | Enum.map(rows, &markdown_row/1)
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @spec publish(String.t(), String.t()) :: :ok | {:error, term()}
  def publish(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      publish_file(path, content)
    end
  end

  defp publish_file(path, content) do
    temporary =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive, :monotonic])}.tmp"
      )

    with :ok <- File.write(temporary, content),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(temporary)
        error
    end
  end

  defp reconcile(examples, artifacts) do
    declarations =
      for example <- examples,
          scenario <- example.scenarios,
          scenario_case <- scenario.cases do
        {{Atom.to_string(example.name), Atom.to_string(scenario.id), Atom.to_string(scenario_case.id)},
         {example, scenario, scenario_case}}
      end

    expected = Map.new(declarations)
    {raw_results, artifact_errors} = extract_artifacts(examples, artifacts)
    {valid, malformed_errors} = validate_raw(raw_results)
    grouped = Enum.group_by(valid, &raw_key/1)

    unknown_errors =
      grouped
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(expected, &1))
      |> Enum.map(&"unknown proof case result: #{format_key(&1)}")

    missing_errors =
      expected
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(grouped, &1))
      |> Enum.map(&"missing proof case result: #{format_key(&1)}")

    duplicate_errors =
      grouped
      |> Enum.filter(fn {_key, results} -> length(results) > 1 end)
      |> Enum.map(fn {key, results} ->
        "duplicate proof case result: #{format_key(key)} (#{length(results)} records)"
      end)

    origin_errors =
      grouped
      |> Enum.flat_map(fn {key, results} ->
        case Map.get(expected, key) do
          {example, _scenario, _scenario_case} ->
            Enum.flat_map(results, &test_origin_errors(&1, example))

          nil ->
            []
        end
      end)

    errors =
      artifact_errors ++
        malformed_errors ++ unknown_errors ++ missing_errors ++ duplicate_errors ++ origin_errors

    cases =
      declarations
      |> Enum.flat_map(fn {key, {example, scenario, scenario_case}} ->
        case Map.get(grouped, key) do
          [raw] ->
            if test_origin_errors(raw, example) == [] do
              [case_result(raw, example, scenario, scenario_case)]
            else
              []
            end

          _missing_or_duplicate ->
            []
        end
      end)
      |> Enum.sort_by(&{&1.example, &1.scenario, &1.case_id})

    gate =
      if errors == [] do
        gate(:proof_results, :ok, nil)
      else
        gate(:proof_results, :error, Enum.join(errors, "\n"))
      end

    {cases, gate}
  end

  defp extract_artifacts(examples, artifacts) do
    Enum.reduce(examples, {[], []}, fn example, {results, errors} ->
      case Map.get(artifacts, example.name) do
        {:ok, %{"schema_version" => @schema_version, "results" => raw}} when is_list(raw) ->
          {results ++ raw, errors}

        {:ok, %{"schema_version" => version}} ->
          {results, errors ++ ["#{example.name}: unsupported proof artifact schema #{inspect(version)}"]}

        {:ok, _artifact} ->
          {results, errors ++ ["#{example.name}: malformed proof artifact"]}

        {:error, reason} ->
          {results, errors ++ ["#{example.name}: cannot read proof artifact: #{inspect(reason)}"]}

        nil ->
          {results, errors ++ ["#{example.name}: proof artifact was not written"]}
      end
    end)
  end

  defp validate_raw(results) do
    Enum.reduce(results, {[], []}, fn raw, {valid, errors} ->
      case raw_error(raw) do
        nil -> {[raw | valid], errors}
        message -> {valid, errors ++ [message]}
      end
    end)
    |> then(fn {valid, errors} -> {Enum.reverse(valid), errors} end)
  end

  defp raw_error(raw) when is_map(raw) do
    required = ["schema_version", "example", "scenario", "case", "status", "test", "duration_ms", "failure"]

    cond do
      Enum.any?(required, &(not Map.has_key?(raw, &1))) ->
        "malformed proof result: missing required fields"

      raw["schema_version"] != @schema_version ->
        "malformed proof result: unsupported schema #{inspect(raw["schema_version"])}"

      not Enum.all?([raw["example"], raw["scenario"], raw["case"]], &is_binary/1) ->
        "malformed proof result: example, scenario, and case must be strings"

      raw["status"] not in ["passed", "failed", "skipped", "excluded", "timed_out"] ->
        "malformed proof result #{format_key(raw_key(raw))}: invalid status #{inspect(raw["status"])}"

      not valid_test?(raw["test"]) ->
        "malformed proof result #{format_key(raw_key(raw))}: invalid test location"

      not is_integer(raw["duration_ms"]) or raw["duration_ms"] < 0 ->
        "malformed proof result #{format_key(raw_key(raw))}: invalid duration"

      not (is_nil(raw["failure"]) or is_binary(raw["failure"])) ->
        "malformed proof result #{format_key(raw_key(raw))}: invalid failure"

      true ->
        nil
    end
  end

  defp raw_error(_raw), do: "malformed proof result: record must be an object"

  defp valid_test?(test) when is_map(test) do
    is_binary(test["file"]) and is_integer(test["line"]) and test["line"] >= 0 and
      is_binary(test["name"])
  end

  defp valid_test?(_test), do: false

  defp test_origin_errors(raw, example) do
    repository_root = example.root |> Path.dirname() |> Path.dirname()
    expected_files = Enum.map(example.test_files, &Path.relative_to(&1, repository_root))

    if raw["test"]["file"] in expected_files do
      []
    else
      [
        "proof result #{format_key(raw_key(raw))} came from undeclared test file " <>
          inspect(raw["test"]["file"])
      ]
    end
  end

  defp case_result(raw, example, scenario, scenario_case) do
    %CaseResult{
      agent: example.agent,
      case_id: scenario_case.id,
      duration_ms: raw["duration_ms"],
      example: example.name,
      execution: scenario.execution,
      failure: raw["failure"],
      proves: scenario_case.proves,
      scenario: scenario.id,
      status: status(raw["status"]),
      test: %{
        file: raw["test"]["file"],
        line: raw["test"]["line"],
        name: raw["test"]["name"]
      },
      uses: scenario_case.uses
    }
  end

  defp coverage(cases) do
    cases
    |> Enum.filter(&(&1.status == :passed))
    |> Enum.flat_map(fn result ->
      Enum.map(result.proves, fn capability ->
        {capability,
         %{
           case: result.case_id,
           example: result.example,
           scenario: result.scenario,
           test: result.test.file
         }}
      end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {capability, records} ->
      {capability, Enum.sort_by(records, &{&1.example, &1.scenario, &1.case})}
    end)
  end

  defp public_selection(selection) do
    %{
      mode: selection.mode,
      examples: Enum.map(selection.examples, & &1.name),
      reasons: selection.reasons
    }
  end

  defp gate(id, status, message) do
    %GateResult{
      command: nil,
      duration_ms: 0,
      id: id,
      message: message,
      output: nil,
      scope: :infrastructure,
      status: status,
      subject: :proof_results
    }
  end

  defp status("passed"), do: :passed
  defp status("failed"), do: :failed
  defp status("skipped"), do: :skipped
  defp status("excluded"), do: :excluded
  defp status("timed_out"), do: :timed_out

  defp raw_key(raw), do: {raw["example"], raw["scenario"], raw["case"]}
  defp format_key({example, scenario, scenario_case}), do: "#{example}/#{scenario}/#{scenario_case}"

  defp showcase_label(nil), do: "—"
  defp showcase_label(showcase), do: "`#{showcase.route}`"

  defp label(value) do
    value
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp markdown_row(values) do
    values = Enum.map(values, &String.replace(&1, "|", "\\|"))
    "| " <> Enum.join(values, " | ") <> " |"
  end
end
