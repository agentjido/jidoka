defmodule Jidoka.ExecutionEnvironment.RestrictedContractTest do
  use ExUnit.Case, async: true

  alias Jidoka.ExecutionEnvironment.RestrictedContract

  test "builds the v0.1 restricted contract and passes compatibility" do
    assert {:ok, contract} = RestrictedContract.new(valid_attrs())
    assert :ok = RestrictedContract.compatible?(contract)
    assert RestrictedContract.compatibility()["release_target"] == "v0.1"
    assert "consent_required" in RestrictedContract.compatibility()["policy_outcomes"]
  end

  test "requires explicit roots, private home, and cancellation" do
    attrs = valid_attrs()
    roots = Enum.reject(attrs.roots, &(&1.kind == :temporary))

    assert {:error, {:missing_required_roots, [:temporary]}} =
             attrs |> Map.put(:roots, roots) |> RestrictedContract.new!() |> RestrictedContract.compatible?()

    assert {:error, :private_home_required} =
             attrs
             |> put_in([:environment, :private_home], false)
             |> RestrictedContract.new!()
             |> RestrictedContract.compatible?()

    assert {:error, :cancellation_required} =
             attrs
             |> put_in([:cancellation, :enabled], false)
             |> RestrictedContract.new!()
             |> RestrictedContract.compatible?()
  end

  test "rejects raw host paths as credential references" do
    attrs = put_in(valid_attrs(), [:credentials], [%{provider: "openai", source: "env", reference: "/etc/secret"}])
    assert {:error, _reason} = RestrictedContract.new(attrs)
  end

  test "preserves bounded unknown fields without granting authority" do
    attrs = put_in(valid_attrs(), [:unknown], %{"future" => "data"})
    assert {:ok, contract} = RestrictedContract.new(attrs)
    assert contract.unknown["future"] == "data"
    assert :ok = RestrictedContract.compatible?(contract)
  end

  defp valid_attrs do
    digest = Jidoka.ExecutionEnvironment.digest(%{"root" => "fixture"})

    %{
      profile_id: "coding.restricted",
      roots:
        Enum.map(RestrictedContract.root_kinds(), fn kind ->
          %{kind: kind, digest: digest, writable: kind != :toolchain}
        end),
      environment: %{allowlist: ["PATH", "LANG"], private_home: true},
      credentials: [%{provider: "openai", source: "host_env", reference: "env:OPENAI_API_KEY"}],
      network: [%{scope: :loopback, decision: :deny}, %{scope: :external, decision: :deny}],
      resources: %{"wall_time_ms" => 30_000},
      cancellation: %{enabled: true, deadline_ms: 1_000},
      deadline_ms: 30_000,
      cleanup: %{status: :clean, child_processes: 0}
    }
  end
end
