defmodule Jidoka.LitterBoxContractIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :litterbox_contract

  @candidate_revision "2b9ac96da48e0c2eb46c7558a04d025abc09c4e8"

  defmodule AssessmentMapping do
    @moduledoc false
    @behaviour Jidoka.ExecutionEnvironment.Adapter

    @impl true
    def open(_profile, _request, _opts), do: {:error, :assessment_only}

    @impl true
    def acquire(_binding, _opts), do: {:error, :assessment_only}

    @impl true
    def checkpoint(_handle, _binding, _opts), do: {:error, :assessment_only}

    @impl true
    def restore(_binding, _checkpoint, _opts), do: {:error, :assessment_only}

    @impl true
    def fork(_binding, _checkpoint, _opts), do: {:error, :unsupported}

    @impl true
    def close(_handle, _opts), do: {:error, :assessment_only}

    @impl true
    def cleanup(_binding, _opts), do: {:error, :assessment_only}
  end

  setup_all do
    path =
      System.get_env("LITTERBOX_PATH") ||
        Path.expand("../../proj_jido_workspace/litter_box", File.cwd!())

    if File.regular?(Path.join(path, "mix.exs")) do
      append_checkout_code_paths(path)
      {:ok, _applications} = Application.ensure_all_started(:litter_box)
      {:ok, litterbox_path: path}
    else
      raise "set LITTERBOX_PATH to the assessed LitterBox checkout"
    end
  end

  test "the disposable mapping covers the complete Jidoka lifecycle port" do
    assert :ok = Jidoka.ExecutionEnvironment.Conformance.validate(AssessmentMapping)
  end

  test "the assessment is bound to the reviewed source and dependency graph", %{litterbox_path: path} do
    assert {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    assert String.trim(revision) == @candidate_revision

    mix_source = File.read!(Path.join(path, "mix.exs"))
    lock_source = File.read!(Path.join(path, "mix.lock"))

    assert mix_source =~ ~s(@version "0.1.0")
    assert mix_source =~ ~s({:jason, "~> 1.2"})
    assert mix_source =~ ~s({:req, "~> 0.6"})
    assert mix_source =~ ~s({:just_bash, "~> 0.3", optional: true})
    assert mix_source =~ ~s({:lua, "~> 1.0.0-rc.3", optional: true})
    refute File.exists?(Path.join(path, "LICENSE"))

    for locked <- [
          ~s("earmark": {:hex, :earmark, "1.4.49"),
          ~s("hpax": {:hex, :hpax, "1.0.3"),
          ~s("jason": {:hex, :jason, "1.4.5"),
          ~s("just_bash": {:hex, :just_bash, "0.3.0"),
          ~s("lua": {:hex, :lua, "1.0.0-rc.3"),
          ~s("mint": {:hex, :mint, "1.9.0"),
          ~s("req": {:hex, :req, "0.6.1")
        ] do
      assert lock_source =~ locked
    end
  end

  test "the public facade supports a deterministic session but no checkpoint", %{litterbox_path: _path} do
    litterbox = Module.concat(["LitterBox"])
    profile_module = Module.concat(["LitterBox", "Profile"])

    assert {:ok, profile} =
             apply(profile_module, :new, [
               [
                 name: :local_code,
                 backend: :just_bash,
                 runtimes: [:bash],
                 network: :disabled
               ]
             ])

    assert {:ok, session} =
             apply(litterbox, :open_session, [:local_code, [], [profile: profile]])

    assert Map.fetch!(session, :backend) == :just_bash
    assert Map.fetch!(Map.fetch!(session, :capabilities), :exec?)
    refute Map.fetch!(Map.fetch!(session, :capabilities), :checkpoints?)

    assert {:ok, result} =
             apply(litterbox, :exec, [session, [runtime: :bash, source: "echo contract"]])

    assert Map.fetch!(result, :stdout) == "contract\n"
    assert {:error, checkpoint_error} = apply(litterbox, :checkpoint, [session, [], []])
    assert Map.fetch!(checkpoint_error, :message) =~ "does not support checkpoint"
    assert :ok = apply(litterbox, :close_session, [session, []])

    assert {:error, _closed_error} =
             apply(litterbox, :exec, [session, [runtime: :bash, source: "echo late"]])
  end

  test "raw backend controls are accepted by LitterBox and require a trusted adapter boundary", %{
    litterbox_path: _path
  } do
    profile_module = Module.concat(["LitterBox", "Profile"])

    assert {:ok, profile} =
             apply(profile_module, :new, [
               [
                 name: :raw_controls,
                 backend: :docker,
                 image: "example.invalid/runtime:latest",
                 workspace: [mode: :copy_in, host_root: "/private/host/path"],
                 backend_options: %{
                   disable_security_defaults?: true,
                   environment: %{"SECRET" => "value"}
                 }
               ]
             ])

    assert Map.fetch!(profile, :backend) == :docker
    assert get_in(profile, [Access.key!(:workspace), Access.key!(:host_root)]) == "/private/host/path"
    assert get_in(profile, [Access.key!(:backend_options), :disable_security_defaults?])

    assert get_in(profile, [Access.key!(:backend_options), :image]) ==
             "example.invalid/runtime:latest"
  end

  defp append_checkout_code_paths(path) do
    path
    |> Path.join("_build/test/lib/*/ebin")
    |> Path.wildcard()
    |> Enum.each(&Code.append_path/1)
  end
end
