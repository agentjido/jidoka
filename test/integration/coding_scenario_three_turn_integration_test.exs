defmodule Jidoka.CodingScenarioThreeTurnIntegrationTest do
  use ExUnit.Case, async: true

  alias CodingScenario.Oracle
  alias Jidoka.Agent
  alias Jidoka.CodingPack
  alias Jidoka.CodingPack.{GitPort, MutationPort, Read, ShellPort, VerifyPort, Workspace}
  alias Jidoka.Effect

  alias Jidoka.ExecutionEnvironment.{
    AdapterCapabilities,
    Manager,
    PolicyRequest,
    Registration,
    SecurityProfile
  }

  alias Jidoka.Extension.Host
  alias Jidoka.Operation.Source
  alias Jidoka.Policy.Decision
  alias Jidoka.Session
  alias Jidoka.TestSupport.CodingPackMutationBackend, as: MutationBackend
  alias Jidoka.TestSupport.CodingScenarioShellAdapter, as: ShellAdapter

  @profile_digest "sha256:" <> String.duplicate("a", 64)
  @expected_source Path.expand(
                     "../fixtures/coding/rate_limiter/v1/expected/lib/rate_limiter.ex.fixture",
                     __DIR__
                   )

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "jidoka-three-turn-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
      )

    fixture = Oracle.materialize!(root)
    {:ok, mutation_state} = Elixir.Agent.start_link(fn -> %{snapshots: %{}} end)
    {:ok, shell_state} = Elixir.Agent.start_link(fn -> %{events: []} end)
    {:ok, read_barrier} = Elixir.Agent.start_link(fn -> %{blocked: true} end)
    {:ok, mutation} = MutationPort.new(MutationBackend, state: mutation_state)
    workspace = Workspace.new!(root: root, access: [:read, :write, :shell, :git, :verify])
    profile = profile()

    {:ok, manager} =
      Manager.start_link(registration(profile), allow_policy(), root: root, state: shell_state)

    {:ok, binding, _evidence} =
      Manager.open(manager, PolicyRequest.new!(profile_id: profile.profile_id))

    {:ok, shell} =
      ShellPort.new(
        manager,
        binding,
        profile,
        %{
          "git" => %{class: "git", mutation: "read", network: false},
          "mix" => %{class: "verify", mutation: "read", network: false}
        }
      )

    {:ok, git} = GitPort.new(shell)

    {:ok, verify} =
      VerifyPort.new(shell, %{
        "mix-test" => %{
          description: "Run the complete fixture test suite.",
          command: "mix",
          args: ["test"],
          targets: [],
          timeout_ms: 15_000,
          network: false,
          exit_codes: [0]
        }
      })

    request = CodingPack.request()
    read = blocking_read(Workspace.new!(root: root), read_barrier, self())

    {:ok, entry} =
      CodingPack.entry(workspace,
        mutation: mutation,
        shell: shell,
        git: git,
        verify: verify,
        replace_tools: %{"coding.read" => read}
      )

    base_spec =
      Agent.Spec.new!(
        id: "rate-limiter-three-turn-agent",
        instructions: "Inspect, edit, verify, and review the repository with coding tools.",
        model: %{provider: :test, id: "deterministic-coding-model"},
        extensions: [request],
        runtime_defaults: %{max_model_turns: 12, max_parallel_operations: 4}
      )

    {:ok, bootstrap_session} = Session.start(base_spec, "rate-limiter-extension-bootstrap")
    {:ok, host} = Host.open(bootstrap_session, [request], %{CodingPack.id() => entry}, :automation)
    {:ok, compiled} = Source.compile(Host.operation_sources(host))

    spec =
      base_spec
      |> Map.from_struct()
      |> Map.put(:operations, compiled.operations)
      |> Agent.Spec.new!()

    {:ok, session} = Session.start(spec, "rate-limiter-three-turn")

    on_exit(fn ->
      Host.close(host)
      if Process.alive?(manager), do: GenServer.stop(manager)
      File.rm_rf!(root)
    end)

    %{
      capability: compiled.capability,
      fixture: fixture,
      read_barrier: read_barrier,
      session: session,
      shell_state: shell_state
    }
  end

  test "one session inspects, recovers, edits, verifies twice, and reviews Git", context do
    owner = self()
    fixture = context.fixture
    [inspect_turn, implement_turn, _verify_turn] = fixture.scenario["turns"]
    initial_source = File.read!(Path.join(fixture.root, "lib/rate_limiter.ex"))
    expected_source = File.read!(@expected_source)
    initial_digest = portable_digest(initial_source)

    inspect_llm =
      scripted_llm(owner, :inspect, [
        operations([
          operation("coding.read", %{"path" => "lib/rate_limiter.ex"}),
          operation("coding.read", %{"path" => "test/rate_limiter_test.exs"})
        ]),
        final("Inspection complete. No files changed.")
      ])

    inspect_task =
      Task.async(fn ->
        Session.chat(context.session, inspect_turn["prompt"],
          llm: inspect_llm,
          operations: context.capability,
          policy: allow_policy()
        )
      end)

    started_reads =
      Enum.map(1..2, fn _index ->
        assert_receive {:parallel_read_started, path, operation_pid}, 2_000
        {path, operation_pid}
      end)

    assert started_reads |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [
             "lib/rate_limiter.ex",
             "test/rate_limiter_test.exs"
           ]

    Elixir.Agent.update(context.read_barrier, &Map.put(&1, :blocked, false))
    Enum.each(started_reads, fn {path, pid} -> send(pid, {:release_parallel_read, path}) end)

    assert {:ok, after_inspect, "Inspection complete. No files changed."} =
             Task.await(inspect_task, 5_000)

    assert after_inspect.session_id == context.session.session_id
    assert Oracle.observe!(fixture)["changed_paths"] == []

    assert [first_read, second_read] = after_inspect.result.agent_state.operation_results
    assert first_read.operation == "coding.read"
    assert second_read.operation == "coding.read"
    assert first_read.arguments["path"] == "lib/rate_limiter.ex"
    assert second_read.arguments["path"] == "test/rate_limiter_test.exs"

    implement_llm =
      scripted_llm(owner, :implement, [
        operation("coding.edit", %{
          "path" => "lib/rate_limiter.ex",
          "old_text" => initial_source,
          "new_text" => expected_source,
          "expected_before_sha256" => "sha256:" <> String.duplicate("0", 64)
        }),
        operation("coding.read", %{"path" => "lib/rate_limiter.ex"}),
        operation("coding.edit", %{
          "path" => "lib/rate_limiter.ex",
          "old_text" => initial_source,
          "new_text" => expected_source,
          "expected_before_sha256" => initial_digest
        }),
        operation("coding.verify", %{"helper_id" => "mix-test"}),
        final("Implementation complete and verified after one recovered conflict.")
      ])

    assert {:ok, after_implement, "Implementation complete and verified after one recovered conflict."} =
             Session.chat(after_inspect, implement_turn["prompt"],
               llm: implement_llm,
               operations: context.capability,
               policy: allow_policy()
             )

    assert after_implement.session_id == context.session.session_id
    assert_receive {:model_prompt, :implement, 0, implement_prompt}

    assert_content_order(implement_prompt, [
      inspect_turn["prompt"],
      "Inspection complete. No files changed.",
      implement_turn["prompt"]
    ])

    assert Enum.count(implement_prompt, &tool_message?/1) == 2

    [_read_one, _read_two, failed_edit, refreshed_read, successful_edit, first_verify] =
      after_implement.result.agent_state.operation_results

    assert failed_edit.operation == "coding.edit"
    assert failed_edit.output["ok"] == false
    assert failed_edit.output["error"]["code"] == "coding_write_conflict"
    assert failed_edit.metadata.operation_failure.kind == :recoverable
    assert refreshed_read.operation == "coding.read"
    assert successful_edit.operation == "coding.edit"
    assert successful_edit.output["write_method"] == "atomic_replace"
    assert first_verify.operation == "coding.verify"
    assert first_verify.output["status"] == "passed"

    assert first_verify.output["stdout"] =~
             ~r/(?:2 tests, 0 failures|Result: 2 passed)/

    assert Oracle.observe!(fixture)["after_digest"] == fixture.scenario["digests"]["after"]

    changed_requirement =
      "The requirement changed: confirm that keys stay independent at a window boundary. " <>
        "Run the tests again, then review Git status and the final diff. Do not edit tests."

    claims_json = fixture |> Oracle.expected_claims() |> Jason.encode!()

    changed_llm =
      scripted_llm(owner, :changed, [
        operation("coding.verify", %{"helper_id" => "mix-test"}),
        operation("coding.git_status", %{"max_entries" => 20}),
        operation("coding.git_diff", %{"context_lines" => 3, "max_bytes" => 65_536}),
        final(claims_json)
      ])

    assert {:ok, completed, ^claims_json} =
             Session.chat(after_implement, changed_requirement,
               llm: changed_llm,
               operations: context.capability,
               policy: allow_policy()
             )

    assert completed.session_id == context.session.session_id
    assert length(completed.requests) == 3
    assert completed.conversation.turn_count == 3
    assert completed.conversation.continuation_revision == 3

    assert_receive {:model_prompt, :changed, 0, changed_prompt}

    assert_content_order(changed_prompt, [
      inspect_turn["prompt"],
      "Inspection complete. No files changed.",
      implement_turn["prompt"],
      "Implementation complete and verified after one recovered conflict.",
      changed_requirement
    ])

    assert Enum.count(changed_prompt, &tool_message?/1) == 6
    assert_receive {:model_prompt, :changed, 3, reviewed_prompt}
    assert Enum.any?(reviewed_prompt, &(Map.get(&1, :operation) == "coding.git_status"))
    assert Enum.any?(reviewed_prompt, &(Map.get(&1, :operation) == "coding.git_diff"))

    results = completed.result.agent_state.operation_results

    assert Enum.map(results, & &1.operation) == [
             "coding.read",
             "coding.read",
             "coding.edit",
             "coding.read",
             "coding.edit",
             "coding.verify",
             "coding.verify",
             "coding.git_status",
             "coding.git_diff"
           ]

    second_verify = Enum.at(results, 6)
    git_status = Enum.at(results, 7)
    git_diff = Enum.at(results, 8)

    assert second_verify.output["status"] == "passed"
    assert git_status.output["entries"] == [match_path("lib/rate_limiter.ex")]
    assert git_diff.output["files"] == [match_diff_file("lib/rate_limiter.ex")]
    assert git_diff.output["patch"] =~ "+  @type bucket"

    claims = Jason.decode!(claims_json)

    assert {:ok, oracle_evidence} =
             Oracle.verify(fixture, oracle_operations(results), claims)

    assert oracle_evidence["verification"]["status"] == "passed"

    shell_requests =
      context.shell_state
      |> Elixir.Agent.get(& &1.events)
      |> Enum.reverse()
      |> Enum.flat_map(fn
        {:execute, request} -> [request]
        _event -> []
      end)

    assert Enum.count(shell_requests, &(&1["command"] == "mix")) == 2
    assert Enum.count(shell_requests, &(&1["command"] == "git")) == 4
    assert Enum.all?(shell_requests, &(&1["network"] == false))
  end

  defp blocking_read(workspace, barrier, owner) do
    %{operation: operation, handler: handler} = Read.tool(workspace)

    wrapped = fn arguments, context ->
      path = arguments["path"]

      if Elixir.Agent.get(barrier, & &1.blocked) do
        send(owner, {:parallel_read_started, path, self()})

        receive do
          {:release_parallel_read, ^path} -> :ok
        after
          2_000 -> raise "parallel read fixture was not released"
        end
      end

      handler.(arguments, context)
    end

    %{operation: operation, handler: wrapped}
  end

  defp scripted_llm(owner, turn, decisions) do
    {:ok, cursor} = Elixir.Agent.start_link(fn -> 0 end)

    fn intent, _journal, _context ->
      index = Elixir.Agent.get_and_update(cursor, &{&1, &1 + 1})
      send(owner, {:model_prompt, turn, index, prompt_messages(intent)})

      case Enum.fetch(decisions, index) do
        {:ok, decision} -> {:ok, decision}
        :error -> raise "deterministic model received an unexpected call"
      end
    end
  end

  defp prompt_messages(%Effect.Intent{payload: payload}) do
    payload
    |> Jidoka.Schema.get_key(:prompt)
    |> Jidoka.Schema.get_key(:messages, [])
  end

  defp operation(name, arguments), do: %{type: :operation, name: name, arguments: arguments}
  defp operations(calls), do: %{type: :operations, operations: calls}
  defp final(content), do: %{type: :final, content: content}

  defp assert_content_order(messages, expected_contents) do
    indexes =
      Enum.map(expected_contents, fn content ->
        index = Enum.find_index(messages, &(&1.content == content))
        assert is_integer(index), "missing prompt history content: #{inspect(content)}"
        index
      end)

    assert indexes == Enum.sort(indexes)
    assert indexes == Enum.uniq(indexes)
  end

  defp tool_message?(message), do: message.role == :tool

  defp match_path(path) do
    %{
      "index" => " ",
      "kind" => "modified",
      "original_path" => nil,
      "path" => path,
      "staged" => false,
      "unstaged" => true,
      "untracked" => false,
      "worktree" => "M"
    }
  end

  defp match_diff_file(path) do
    %{"additions" => 28, "binary" => false, "deletions" => 5, "path" => path}
  end

  defp oracle_operations([
         read_implementation,
         read_tests,
         failed_edit,
         refreshed_read,
         successful_edit,
         first_verify,
         _second_verify,
         _git_status,
         _git_diff
       ]) do
    assert read_implementation.arguments == %{"path" => "lib/rate_limiter.ex"}
    assert read_tests.arguments == %{"path" => "test/rate_limiter_test.exs"}
    assert failed_edit.output["ok"] == false
    assert refreshed_read.arguments == %{"path" => "lib/rate_limiter.ex"}
    assert successful_edit.output["write_method"] == "atomic_replace"
    assert first_verify.output["status"] == "passed"

    [
      %{"id" => "inspect_implementation", "kind" => "read", "path" => "lib/rate_limiter.ex"},
      %{"id" => "inspect_tests", "kind" => "read", "path" => "test/rate_limiter_test.exs"},
      %{"id" => "recover_stale_edit", "kind" => "edit", "path" => "lib/rate_limiter.ex"},
      %{"id" => "refresh_implementation", "kind" => "read", "path" => "lib/rate_limiter.ex"},
      %{"id" => "edit_implementation", "kind" => "edit", "path" => "lib/rate_limiter.ex"},
      %{"id" => "verify_tests", "kind" => "verify", "command" => "mix test", "status" => "passed"}
    ]
  end

  defp profile do
    SecurityProfile.new!(
      profile_id: "coding-scenario-local",
      revision: 1,
      digest: @profile_digest,
      adapter_id: "test.coding-scenario-shell",
      required_isolation: :process,
      required_network: :disabled,
      required_workspace: :isolated_copy,
      maximum_limits: %{"wall_time_ms" => 60_000, "output_bytes" => 262_144}
    )
  end

  defp registration(profile) do
    capabilities =
      AdapterCapabilities.new!(
        adapter_id: profile.adapter_id,
        adapter_version: "1",
        isolations: [:process],
        networks: [:disabled],
        workspaces: [:isolated_copy],
        limit_keys: ["wall_time_ms", "output_bytes"],
        capability_ids: ["shell.execute"]
      )

    Registration.new!(profile: profile, adapter: ShellAdapter, capabilities: capabilities)
  end

  defp allow_policy do
    fn _request, _context -> {:ok, Decision.new!(outcome: :allow, rule_id: "test.allow")} end
  end

  defp portable_digest(content) do
    "sha256:" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))
  end
end
