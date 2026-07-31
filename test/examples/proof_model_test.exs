Code.require_file("../../examples/_support/registry.exs", __DIR__)
Code.require_file("../../examples/_support/check.exs", __DIR__)

defmodule JidokaExamples.ProofModelTest do
  use ExUnit.Case, async: false

  alias Jidoka.Effect
  alias JidokaExamples.{Catalog, Executor, Planner, Reporter}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "jidoka-proof-model-#{System.unique_integer([:positive, :monotonic])}"
      )

    examples_root = Path.join(root, "examples")
    File.mkdir_p!(examples_root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{examples_root: examples_root, root: root}
  end

  test "catalog loads two valid examples and discovers multiple test files", %{examples_root: root} do
    write_example(root, :alpha, test_files: ["first_test.exs", "nested/second_test.exs"])
    write_example(root, :beta)

    assert {examples, []} = Catalog.load(root)
    assert Enum.map(examples, & &1.name) == [:alpha, :beta]

    alpha = Enum.find(examples, &(&1.name == :alpha))
    assert length(alpha.test_files) == 2
    assert Enum.all?(alpha.test_files, &String.ends_with?(&1, "_test.exs"))
  end

  test "catalog reports strict case and surface errors", %{examples_root: root} do
    manifest = valid_manifest(:invalid)

    invalid_case = %{
      id: "not-an-atom",
      proves: [:unknown_capability],
      uses: [:tool_calling]
    }

    manifest =
      put_in(manifest, [:scenarios, Access.at(0), :cases], [
        invalid_case,
        %{id: :duplicate, proves: [], uses: []},
        %{id: :duplicate, proves: [:tool_calling], uses: [:tool_calling]}
      ])
      |> put_in([:surfaces, :showcase], %{
        route: "support",
        live_view: NotAModule,
        view: NotAModule,
        tests: ["../unsafe_test.exs"],
        sources: []
      })

    write_manifest(root, :invalid, manifest)

    assert {[], errors} = Catalog.load(root)
    messages = Enum.map_join(errors, "\n", & &1.message)

    assert messages =~ "id must be a snake_case identifier"
    assert messages =~ "unknown capability in proves"
    assert messages =~ "proves must be a non-empty list"
    assert messages =~ "overlapping proves and uses"
    assert messages =~ "duplicate case"
    assert messages =~ "showcase route must start with /"
    assert messages =~ "safe relative paths"
  end

  test "catalog rejects an example without proof test files", %{examples_root: root} do
    write_example(root, :no_tests, test_files: [])

    assert {[], errors} = Catalog.load(root)
    assert Enum.any?(errors, &(&1.message == "no proof test files were found"))
  end

  test "catalog loads YAML examples without an example-local support folder", %{examples_root: root} do
    write_example(root, :shared_support)
    File.rm_rf!(Path.join(root, "shared_support/support"))

    assert [%{name: :shared_support}] = Catalog.load!(root)
  end

  test "catalog reports malformed and multi-document YAML", %{examples_root: root} do
    malformed_root = Path.join(root, "malformed")
    File.mkdir_p!(malformed_root)
    File.write!(Path.join(malformed_root, "manifest.yaml"), "scenarios: [")

    multi_root = Path.join(root, "multi")
    File.mkdir_p!(multi_root)
    File.write!(Path.join(multi_root, "manifest.yaml"), "---\nversion: 2\n---\nversion: 2\n")

    assert {[], errors} = Catalog.load(root)
    messages = Enum.map_join(errors, "\n", & &1.message)
    assert messages =~ "cannot parse YAML manifest"
    assert messages =~ "manifest must contain one YAML document"
  end

  test "shared Mock LLM runs an operation round trip and preserves a nil observation" do
    llm =
      JidokaExamples.MockLLM.operation_round_trip(
        operation: "read_value",
        arguments: %{"id" => "one"},
        final: &inspect/1,
        on_observation: &send(self(), {:observed, &1})
      )

    first_intent = Effect.Intent.new(:llm, %{prompt: %{messages: []}})
    journal = Effect.Journal.new!()

    assert {:ok, %{type: :operation, name: "read_value", arguments: %{"id" => "one"}}} =
             llm.(first_intent, journal, %{})

    second_intent =
      Effect.Intent.new(:llm, %{
        prompt: %{
          messages: [%{role: :tool, operation: "read_value", output: nil}]
        }
      })

    assert {:ok, %{type: :final, content: "nil"}} = llm.(second_intent, journal, %{})
    assert_receive {:observed, nil}
  end

  test "reporter accepts one passed result and derives coverage", %{examples_root: root} do
    write_example(root, :alpha)
    [example] = Catalog.load!(root)
    artifact = artifact([raw_result(:alpha, "passed")])

    report = Reporter.build(selection([example]), [], %{alpha: {:ok, artifact}})

    assert report.status == :ok
    assert [%{status: :passed, agent: JidokaExamples.Alpha.Agent}] = report.cases
    assert %{tool_calling: [%{case: :main_path, example: :alpha}]} = report.coverage
  end

  test "failed, skipped, excluded, and timed-out cases prove nothing", %{examples_root: root} do
    write_example(root, :alpha)
    [example] = Catalog.load!(root)

    for status <- ~w(failed skipped excluded timed_out) do
      report =
        Reporter.build(
          selection([example]),
          [],
          %{alpha: {:ok, artifact([raw_result(:alpha, status)])}}
        )

      assert report.status == :error
      assert report.coverage == %{}
      assert [%{status: result_status}] = report.cases
      assert Atom.to_string(result_status) == status
    end
  end

  test "reporter rejects missing, duplicate, unknown, and malformed case records", %{
    examples_root: root
  } do
    write_example(root, :alpha)
    [example] = Catalog.load!(root)

    duplicate = raw_result(:alpha, "passed")
    unknown = %{duplicate | "case" => "unknown"}
    malformed = Map.delete(duplicate, "status")

    report =
      Reporter.build(
        selection([example]),
        [],
        %{alpha: {:ok, artifact([duplicate, duplicate, unknown, malformed])}}
      )

    proof_gate = Enum.find(report.gates, &(&1.id == :proof_results))
    assert report.status == :error
    assert proof_gate.message =~ "duplicate proof case result"
    assert proof_gate.message =~ "unknown proof case result"
    assert proof_gate.message =~ "malformed proof result"

    missing = Reporter.build(selection([example]), [], %{})
    missing_gate = Enum.find(missing.gates, &(&1.id == :proof_results))
    assert missing_gate.message =~ "proof artifact was not written"
    assert missing_gate.message =~ "missing proof case result"
  end

  test "reporter sorts asynchronous results by example, scenario, and case", %{
    examples_root: root
  } do
    cases = [
      %{id: :a_case, proves: [:tool_calling], uses: [:agent]},
      %{id: :z_case, proves: [:tool_observation], uses: [:action]}
    ]

    write_example(root, :alpha, cases: cases)
    [example] = Catalog.load!(root)

    z = raw_result(:alpha, "passed", "z_case")
    a = raw_result(:alpha, "passed", "a_case")
    report = Reporter.build(selection([example]), [], %{alpha: {:ok, artifact([z, a])}})

    assert Enum.map(report.cases, & &1.case_id) == [:a_case, :z_case]
  end

  test "ExUnit formatter records all proof statuses in stable order", %{root: root} do
    path = Path.join(root, "formatter.json")
    previous = System.get_env("JIDOKA_PROOF_RESULT_PATH")
    System.put_env("JIDOKA_PROOF_RESULT_PATH", path)

    on_exit(fn ->
      if previous do
        System.put_env("JIDOKA_PROOF_RESULT_PATH", previous)
      else
        System.delete_env("JIDOKA_PROOF_RESULT_PATH")
      end
    end)

    {:ok, formatter} = GenServer.start_link(JidokaExamples.ExUnitFormatter, [])

    states = [
      {:a_passed, nil},
      {:b_failed, {:failed, [{:error, RuntimeError.exception("failed"), []}]}},
      {:c_skipped, {:skipped, "skip"}},
      {:d_excluded, {:excluded, "exclude"}},
      {:e_timed_out,
       {:failed,
        [
          {:error, ExUnit.TimeoutError.exception(timeout: 5, type: "test"), []}
        ]}}
    ]

    Enum.each(Enum.reverse(states), fn {case_id, state} ->
      test = %ExUnit.Test{
        name: String.to_atom("test #{case_id}"),
        state: state,
        time: 1_000,
        tags: %{
          file: __ENV__.file,
          line: __ENV__.line,
          proof_example: :alpha,
          proof_case: {:scenario, case_id}
        }
      }

      GenServer.cast(formatter, {:test_finished, test})
    end)

    GenServer.cast(formatter, {:suite_finished, %{run: 1_000, load: 0}})
    :sys.get_state(formatter)

    artifact = path |> File.read!() |> Jason.decode!()

    assert Enum.map(artifact["results"], &{&1["case"], &1["status"]}) == [
             {"a_passed", "passed"},
             {"b_failed", "failed"},
             {"c_skipped", "skipped"},
             {"d_excluded", "excluded"},
             {"e_timed_out", "timed_out"}
           ]
  end

  test "planner separates focused, full, guide-only, and empty plans" do
    examples = Catalog.load!()

    assert {:ok, focused} = Planner.plan(examples, [example: "support-agent"], File.cwd!())
    assert focused.mode == :example
    assert Enum.map(focused.examples, & &1.name) == [:support_agent]

    assert Enum.map(focused.gates, & &1.id) == [
             :root_compile,
             :support_agent_exunit,
             :support_agent_livebook,
             :showcase_compile,
             :showcase_test
           ]

    assert hd(focused.gates).timeout_ms == 240_000

    assert {:ok, full} = Planner.plan(examples, [], File.cwd!())
    assert full.mode == :all
    assert Enum.any?(full.gates, &(&1.id == :documentation))
    assert Enum.count(full.gates, &(&1.id == :showcase_compile)) == 1
    assert Enum.count(full.gates, &(&1.id == :showcase_test)) == 1

    guide = "guides/livebooks/workflows.livemd"

    assert {:ok, guide_plan} =
             Planner.plan(examples, [changed_paths: [change("M", guide)]], File.cwd!())

    assert guide_plan.examples == []
    assert Enum.map(guide_plan.gates, & &1.scope) == [:infrastructure, :guide]

    assert {:ok, empty} =
             Planner.plan(examples, [changed_paths: [change("M", "notes.txt")]], File.cwd!())

    assert empty.examples == []
    assert empty.gates == []

    assert {:ok, documentation} =
             Planner.plan(
               examples,
               [changed_paths: [change("M", "examples/README.md")]],
               File.cwd!()
             )

    assert Enum.map(documentation.gates, & &1.id) == [:root_compile, :documentation]

    assert {:ok, deleted_guide} =
             Planner.plan(
               examples,
               [changed_paths: [change("D", "guides/livebooks/removed.livemd")]],
               File.cwd!()
             )

    assert Enum.map(deleted_guide.gates, & &1.id) == [:root_compile, :documentation]
  end

  test "planner applies shared, showcase, rename, and deletion impacts" do
    examples = Catalog.load!()

    for path <- [
          "examples/_support/reporter.ex",
          "examples/_support/catalog.exs",
          "lib/jidoka.ex",
          "test/support/test_support.ex",
          "examples/_support/check_livebook.exs",
          "mix.exs",
          "config/config.exs"
        ] do
      assert {:ok, plan} =
               Planner.plan(examples, [changed_paths: [change("M", path)]], File.cwd!())

      assert Enum.map(plan.examples, & &1.name) == [:support_agent]
    end

    source = "showcase/lib/jidoka_showcase_web/live/support_agent_live/index.ex"

    assert {:ok, owned} =
             Planner.plan(examples, [changed_paths: [change("M", source)]], File.cwd!())

    assert Enum.map(owned.examples, & &1.name) == [:support_agent]

    assert {:ok, shared} =
             Planner.plan(
               examples,
               [changed_paths: [change("M", "showcase/lib/jidoka_showcase/application.ex")]],
               File.cwd!()
             )

    assert Enum.map(shared.examples, & &1.name) == [:support_agent]
    assert shared.global?

    rename = %{status: "R100", paths: ["examples/support_agent/old.ex", "examples/support_agent/new.ex"]}
    assert {:ok, renamed} = Planner.plan(examples, [changed_paths: [rename]], File.cwd!())
    assert Enum.map(renamed.examples, & &1.name) == [:support_agent]

    deletion = change("D", "examples/removed_agent/manifest.yaml")
    assert {:ok, deleted} = Planner.plan(examples, [changed_paths: [deletion]], File.cwd!())
    assert Enum.map(deleted.examples, & &1.name) == [:support_agent]
    assert deleted.global?
  end

  test "executor records exits, timeout output, skipped stages, and stable gate order" do
    gates = [
      command_gate(
        :timeout,
        0,
        ["elixir", "-e", "IO.puts(\"partial\"); Process.sleep(2_000)"],
        1_000
      ),
      command_gate(:later, 1, ["elixir", "-e", "IO.puts(\"must not run\")"], 500)
    ]

    result = Executor.run(gates)

    assert Enum.map(result.gates, & &1.id) == [:timeout, :later]
    assert [timeout, skipped] = result.gates
    assert timeout.status == :error
    assert timeout.message =~ "Timed out"
    assert timeout.output =~ "partial"
    assert skipped.status == :skipped

    exit_result = Executor.run([command_gate(:exit, 0, ["elixir", "-e", "System.halt(7)"], 500)])
    assert [%{status: :error, message: "Exited with status 7."}] = exit_result.gates

    missing = Executor.run([command_gate(:missing, 0, ["jidoka-command-that-does-not-exist"], 500)])
    assert [%{status: :error, message: message}] = missing.gates
    assert message =~ "Executable is not available"
  end

  test "Livebook failures name the code cell and source line", %{root: root} do
    path = Path.join(root, "failure.livemd")

    File.write!(path, """
    # Failure

    ```elixir
    value = 1
    ```

    ```elixir
    raise "cell failed"
    ```
    """)

    gate =
      command_gate(
        :livebook_failure,
        0,
        [
          "mix",
          "run",
          "--no-compile",
          "--no-deps-check",
          "examples/_support/check_livebook.exs",
          "--",
          "--project",
          path
        ],
        5_000
      )

    assert %{gates: [%{status: :error, output: output}]} = Executor.run([gate])
    assert output =~ "Livebook cell 2"
    assert output =~ path
    assert output =~ "cell failed"
  end

  test "proof document publishing creates its local documentation directory", %{root: root} do
    path = Path.join(root, "docs/PROVEN_FEATURES.md")

    assert :ok = Reporter.publish(path, "# Proven Features\n")
    assert File.read!(path) == "# Proven Features\n"
  end

  test "normal Mix project startup does not evaluate the example catalog" do
    mix_source = File.read!(Path.join(File.cwd!(), "mix.exs"))
    showcase_mix_source = File.read!(Path.join(File.cwd!(), "showcase/mix.exs"))

    refute mix_source =~ "JidokaExamples.Catalog.load!"
    refute showcase_mix_source =~ "JidokaExamples.Catalog.load!"
    assert showcase_mix_source =~ "../examples/*/lib"
    assert Mix.Project.config()[:app] == :jidoka
    assert "examples/_support" in Mix.Project.config()[:elixirc_paths]
  end

  test "registry rejects compiler warnings in example support", %{examples_root: root} do
    write_example(root, :warning_agent)
    scenario_root = Path.join(root, "warning_agent")

    File.write!(Path.join(scenario_root, "lib/warning.ex"), """
    defmodule JidokaExamples.WarningAgent.Warning do
      def value do
        unused = :warning
        :ok
      end
    end
    """)

    [example] = Catalog.load!(root)
    parent = self()

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      send(parent, {:warning_result, JidokaExamples.load(example)})
    end)

    assert_receive {:warning_result, {:error, {:compile_warnings, _warnings}}}
  end

  test "registry rejects duplicate helper modules across owned folders", %{examples_root: root} do
    write_example(root, :duplicate_agent)
    scenario_root = Path.join(root, "duplicate_agent")

    File.write!(Path.join(scenario_root, "lib/duplicate.ex"), """
    defmodule JidokaExamples.DuplicateAgent.Helper do
    end
    """)

    [example] = Catalog.load!(root)
    parent = self()

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      send(parent, {:duplicate_result, JidokaExamples.load(example)})
    end)

    assert_receive {:duplicate_result, {:error, reason}}

    assert match?({:compile_warnings, _warnings}, reason) or
             match?({:compile_failed, _errors, _warnings}, reason)
  end

  defp write_example(root, name, opts \\ []) do
    write_manifest(root, name, valid_manifest(name, opts))
    scenario_root = Path.join(root, Atom.to_string(name))
    File.mkdir_p!(Path.join(scenario_root, "lib"))
    File.mkdir_p!(Path.join(scenario_root, "support"))

    files = Keyword.get(opts, :test_files, ["proof_test.exs"])

    Enum.each(files, fn relative ->
      path = Path.join([scenario_root, "test", relative])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# test fixture\n")
    end)

    namespace = Macro.camelize(Atom.to_string(name))

    File.write!(Path.join(scenario_root, "lib/agent.ex"), """
    defmodule JidokaExamples.#{namespace}.Agent do
    end
    """)

    File.write!(Path.join(scenario_root, "support/helper.ex"), """
    defmodule JidokaExamples.#{namespace}.Helper do
    end
    """)

    File.write!(Path.join(scenario_root, "example.exs"), """
    defmodule JidokaExamples.#{namespace}.Example do
      def run(_opts), do: {:ok, :example}
    end
    """)

    File.write!(Path.join(scenario_root, "README.md"), "# #{namespace} Agent\n")

    File.write!(
      Path.join(scenario_root, "#{name}.livemd"),
      "# #{namespace} Agent\n\n```elixir\n:ok\n```\n"
    )
  end

  defp write_manifest(root, name, manifest) do
    scenario_root = Path.join(root, Atom.to_string(name))
    File.mkdir_p!(scenario_root)
    File.write!(Path.join(scenario_root, "manifest.yaml"), Ymlr.document!(manifest))
  end

  defp valid_manifest(name, opts \\ []) do
    namespace = Macro.camelize(Atom.to_string(name))
    cases = Keyword.get(opts, :cases, [%{id: :main_path, proves: [:tool_calling], uses: [:agent]}])

    %{
      version: 2,
      name: name,
      title: "#{namespace} Agent",
      summary: "A valid temporary proof example.",
      module: Module.concat([JidokaExamples, namespace, Example]),
      agent: Module.concat([JidokaExamples, namespace, Agent]),
      scenarios: [
        %{
          id: :scenario,
          title: "Scenario",
          intent: "Verify one temporary path.",
          execution: :deterministic,
          cases: cases
        }
      ],
      surfaces: %{livebook: true, showcase: false}
    }
  end

  defp selection(examples) do
    %{mode: :example, examples: examples, guides: [], global?: false, reasons: []}
  end

  defp artifact(results), do: %{"schema_version" => 1, "results" => results}

  defp raw_result(example, status, case_id \\ "main_path") do
    %{
      "schema_version" => 1,
      "example" => Atom.to_string(example),
      "scenario" => "scenario",
      "case" => case_id,
      "status" => status,
      "test" => %{
        "file" => "examples/#{example}/test/proof_test.exs",
        "line" => 10,
        "name" => "test proof"
      },
      "duration_ms" => 1,
      "failure" => if(status == "passed", do: nil, else: status)
    }
  end

  defp change(status, path), do: %{status: status, paths: [path]}

  defp command_gate(id, stage, command, timeout_ms) do
    %{
      id: id,
      stage: stage,
      scope: :infrastructure,
      subject: id,
      cd: File.cwd!(),
      command: command,
      timeout_ms: timeout_ms
    }
  end
end
