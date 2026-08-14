defmodule CodingScenario.OracleTest do
  use ExUnit.Case, async: true

  alias CodingScenario.Oracle

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "coding-scenario-oracle-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, tmp_dir: root}
  end

  test "materializes the data-only scenario repeatably", %{tmp_dir: tmp_dir} do
    first = Oracle.materialize!(Path.join(tmp_dir, "first"))
    second = Oracle.materialize!(Path.join(tmp_dir, "second"))

    assert first.scenario["version"] == 1
    assert Enum.map(first.scenario["turns"], & &1["id"]) == ["inspect", "implement", "verify"]
    assert first.revision == second.revision
    assert Oracle.observe!(first) == Oracle.observe!(second)
    assert Oracle.observe!(first)["changed_paths"] == []
  end

  test "accepts the exact implementation, operation order, claims, and verification", %{tmp_dir: tmp_dir} do
    fixture = completed_fixture(tmp_dir)

    assert {:ok, evidence} =
             Oracle.verify(fixture, Oracle.valid_operations(), Oracle.expected_claims(fixture))

    assert evidence["changed_paths"] == ["lib/rate_limiter.ex"]
    assert evidence["verification"]["status"] == "passed"
    assert evidence["verification"]["output"] =~ "Result: 2 passed"
  end

  test "rejects an extra repository change", %{tmp_dir: tmp_dir} do
    fixture = completed_fixture(tmp_dir)
    File.write!(Path.join(fixture.root, "NOTES.md"), "not allowed\n")

    assert {:error, errors} = verify_expected(fixture)
    assert {:unexpected_changed_paths, ["NOTES.md", "lib/rate_limiter.ex"]} in errors
  end

  test "rejects test tampering", %{tmp_dir: tmp_dir} do
    fixture = completed_fixture(tmp_dir)
    File.write!(Path.join(fixture.root, "test/rate_limiter_test.exs"), "# changed\n", [:append])

    assert {:error, errors} = verify_expected(fixture)
    assert {:protected_paths_changed, ["test/rate_limiter_test.exs"]} in errors
  end

  test "rejects missing verification evidence", %{tmp_dir: tmp_dir} do
    fixture = completed_fixture(tmp_dir)
    operations = Enum.reject(Oracle.valid_operations(), &(&1["kind"] == "verify"))

    assert {:error, errors} =
             Oracle.verify(fixture, operations, Oracle.expected_claims(fixture))

    assert :missing_verification in errors
    assert {:missing_operation, "verify_tests"} in errors
  end

  test "rejects an operation order that violates the partial order", %{tmp_dir: tmp_dir} do
    fixture = completed_fixture(tmp_dir)
    operations = Enum.reverse(Oracle.valid_operations())

    assert {:error, errors} =
             Oracle.verify(fixture, operations, Oracle.expected_claims(fixture))

    assert :operation_order_violation in errors
  end

  test "rejects false model claims", %{tmp_dir: tmp_dir} do
    fixture = completed_fixture(tmp_dir)
    claims = Map.put(Oracle.expected_claims(fixture), "changed_paths", [])

    assert {:error, errors} = Oracle.verify(fixture, Oracle.valid_operations(), claims)
    assert Enum.any?(errors, &match?({:model_claim_mismatch, _, _}, &1))
  end

  defp completed_fixture(tmp_dir) do
    tmp_dir
    |> Path.join("repository")
    |> Oracle.materialize!()
    |> Oracle.install_expected!()
  end

  defp verify_expected(fixture) do
    Oracle.verify(fixture, Oracle.valid_operations(), Oracle.expected_claims(fixture))
  end
end
