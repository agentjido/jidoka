defmodule JidokaExamples.ManifestTest do
  use ExUnit.Case, async: true

  @moduletag example: :manifest

  @identifier ~r/^[a-z][a-z0-9_]*$/
  @required_keys ~w(agent features livebook name summary tests title)
  @milestone_features %{
    "A01" => ["code_first_authoring"],
    "A02" => ["data_defined_authoring"],
    "A03" => ["dynamic_instructions"],
    "A04" => ["typed_context"],
    "A05" => ["provider_model_abstraction"],
    "A06" => ["model_routing"],
    "A07" => ["structured_results"],
    "A08" => ["result_repair"],
    "A09" => ["multimodal_content"],
    "E01" => ["synchronous_execution", "async_execution"],
    "E02" => ["event_streaming"],
    "E03" => ["parallel_tool_calling"],
    "E04" => ["execution_budgets"],
    "E05" => ["cancellation"],
    "E06" => ["serializable_pause_resume"],
    "E07" => ["crash_recovery"],
    "E08" => ["data_only_replay", "safe_session_fork"],
    "W01" => ["sequential_typed_steps"],
    "W02" => ["conditional_routing"],
    "W03" => ["parallel_fan_out"],
    "W04" => ["bounded_dynamic_loops"],
    "W05" => ["bounded_step_retry"],
    "W06" => ["workflow_tool"],
    "W07" => ["background_runs"],
    "W08" => ["scheduled_runs"]
  }

  @existing_capability_features %{
    "G01" => ["input_controls"],
    "G02" => ["output_controls"],
    "G03" => ["operation_policy"],
    "G05" => ["trace_redaction"],
    "M04" => ["static_multi_agent_workflow"],
    "O01" => ["lifecycle_events"],
    "O02" => ["local_inspection"],
    "O03" => ["local_trace_sink"],
    "O04" => ["usage_accounting"],
    "O05" => ["deterministic_evals"],
    "O06" => ["repeatable_eval_cases"],
    "O07" => ["trajectory_assertions"],
    "R01" => ["process_hosted_agent"],
    "R04" => ["local_developer_notebook"],
    "R05" => ["ui_projection"],
    "R07" => ["provider_free_testing"],
    "S02" => ["checkpoint_state"],
    "T01" => ["schema_derived_tools"],
    "T02" => ["static_tool_narrowing"],
    "T03" => ["catalog_discovery"],
    "T04" => ["skill_bundle"],
    "T06" => ["effect_idempotency"],
    "T11" => ["read_only_browser_tools"]
  }

  test "each example has valid metadata and required files" do
    manifests = Path.wildcard("examples/*/manifest.yaml") |> Enum.sort()
    example_dirs = example_dirs()

    assert manifests != []
    assert Enum.map(manifests, &Path.dirname/1) == example_dirs

    names = Enum.map(manifests, &validate_manifest!/1)
    assert names == Enum.uniq(names)
  end

  test "examples cover every feature in the completed parity sections" do
    features = manifest_features()

    expected_ids =
      Enum.map(1..9, &"A0#{&1}") ++
        Enum.map(1..8, &"E0#{&1}") ++
        Enum.map(1..8, &"W0#{&1}")

    assert @milestone_features |> Map.keys() |> Enum.sort() == expected_ids

    for {id, required_features} <- @milestone_features,
        feature <- required_features do
      assert MapSet.member?(features, feature),
             "#{id} is missing its #{feature} example coverage"
    end
  end

  test "examples cover every shipped feature that had proof debt" do
    features = manifest_features()

    assert @existing_capability_features |> Map.keys() |> Enum.sort() ==
             ~w(G01 G02 G03 G05 M04 O01 O02 O03 O04 O05 O06 O07 R01 R04 R05 R07 S02 T01 T02 T03 T04 T06 T11)

    for {id, required_features} <- @existing_capability_features,
        feature <- required_features do
      assert MapSet.member?(features, feature),
             "#{id} is missing its #{feature} example coverage"
    end
  end

  defp validate_manifest!(path) do
    assert {:ok, [manifest]} = YamlElixir.read_all_from_file(path)
    assert Map.keys(manifest) |> Enum.sort() == @required_keys

    root = Path.dirname(path)
    name = manifest["name"]
    features = manifest["features"]
    tests = manifest["tests"]

    assert name == Path.basename(root)
    assert name =~ @identifier
    assert is_binary(manifest["title"]) and manifest["title"] != ""
    assert is_binary(manifest["summary"]) and manifest["summary"] != ""
    assert is_list(features) and features != []
    assert features == Enum.uniq(features)
    assert Enum.all?(features, &(&1 =~ @identifier))
    assert is_list(tests) and tests != []

    assert File.regular?(Path.join(root, "README.md"))
    assert File.regular?(Path.join(root, "example.exs"))
    assert File.regular?(Path.join(root, "lib/agent.ex"))
    assert File.regular?(Path.join(root, manifest["livebook"]))
    assert Enum.all?(tests, &File.regular?(Path.join(root, &1)))

    module = manifest["agent"] |> String.split(".") |> Module.safe_concat()
    assert Code.ensure_loaded?(module)

    name
  end

  defp example_dirs do
    "examples/*"
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.reject(&(Path.basename(&1) |> String.starts_with?("_")))
    |> Enum.sort()
  end

  defp manifest_features do
    "examples/*/manifest.yaml"
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      {:ok, [manifest]} = YamlElixir.read_all_from_file(path)
      manifest["features"]
    end)
    |> MapSet.new()
  end
end
