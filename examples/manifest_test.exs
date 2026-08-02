defmodule JidokaExamples.ManifestTest do
  use ExUnit.Case, async: true

  @moduletag example: :manifest

  @identifier ~r/^[a-z][a-z0-9_]*$/
  @required_keys ~w(agent features livebook name summary tests title)

  test "each example has valid metadata and required files" do
    manifests = Path.wildcard("examples/*/manifest.yaml") |> Enum.sort()
    example_dirs = example_dirs()

    assert manifests != []
    assert Enum.map(manifests, &Path.dirname/1) == example_dirs

    names = Enum.map(manifests, &validate_manifest!/1)
    assert names == Enum.uniq(names)
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
end
