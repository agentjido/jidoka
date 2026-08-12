defmodule Jidoka.Replay.CapabilityFixtureTest do
  use ExUnit.Case, async: true

  alias Jidoka.Replay.Environment
  alias Jidoka.Replay.Fixture
  alias Jidoka.Replay.Recorder

  test "records redacted portable calls and survives a verified JSON round trip" do
    {:ok, recorder} =
      Recorder.start_recording(
        compatibility: %{"runtime" => "jidoka-v1"},
        redact_strings: ["literal-secret"]
      )

    assert {:ok, %{"api_key" => "literal-secret", "answer" => "literal-secret done"}} =
             Recorder.capture(recorder, :llm, :invoke, %{prompt: "hello"}, fn ->
               {:ok, %{"api_key" => "literal-secret", "answer" => "literal-secret done"}}
             end)

    assert {:ok, fixture} = Recorder.fixture(recorder)
    assert fixture.digest =~ "sha256:"
    assert [%{class: "llm", occurrence: 1, outcome: "ok"}] = fixture.entries

    assert {:ok, json} = Fixture.encode_json(fixture)
    refute json =~ "literal-secret"
    assert json =~ "[REDACTED]"
    assert {:ok, decoded} = Fixture.decode_json(json)
    assert decoded == fixture

    {:ok, player} = Recorder.start_replay(decoded, compatibility: %{"runtime" => "jidoka-v1"})

    assert {:ok, %{"api_key" => "[REDACTED]", "answer" => "[REDACTED] done"}} =
             Recorder.capture(player, :llm, :invoke, %{prompt: "hello"}, fn -> flunk("live call") end)

    assert :ok = Recorder.finish(player)

    assert %{
             "mode" => "replay",
             "live" => false,
             "fixture_digest" => digest,
             "matched_calls" => 1,
             "total_calls" => 1
           } = Recorder.provenance(player)

    assert digest == fixture.digest
  end

  test "fails closed for changed, missing, extra, and out-of-order calls" do
    {:ok, recorder} = Recorder.start_recording()
    assert {:ok, :first} = Recorder.capture(recorder, :llm, :invoke, %{input: "one"}, fn -> {:ok, :first} end)
    assert {:ok, :second} = Recorder.capture(recorder, :operation, :lookup, %{id: 2}, fn -> {:ok, :second} end)
    {:ok, fixture} = Recorder.fixture(recorder)

    {:ok, changed} = Recorder.start_replay(fixture)

    assert {:error, {:capability_replay_mismatch, expected, actual}} =
             Recorder.capture(changed, :llm, :invoke, %{input: "changed"}, fn -> :unreachable end)

    assert expected["class"] == "llm"
    assert actual["class"] == "llm"

    {:ok, wrong_order} = Recorder.start_replay(fixture)

    assert {:error, {:capability_replay_mismatch, %{"class" => "llm"}, %{"class" => "operation"}}} =
             Recorder.capture(wrong_order, :operation, :lookup, %{id: 2}, fn -> :unreachable end)

    {:ok, extra} = Recorder.start_replay(fixture)
    assert {:error, {:capability_replay_extra_calls, 1, 2}} = Recorder.finish(extra)

    assert {:ok, :first} = Recorder.capture(extra, :llm, :invoke, %{input: "one"}, fn -> :unreachable end)
    assert {:ok, :second} = Recorder.capture(extra, :operation, :lookup, %{id: 2}, fn -> :unreachable end)

    assert {:error, {:capability_replay_missing_call, %{"index" => 3}}} =
             Recorder.capture(extra, :policy, :allow, %{}, fn -> :unreachable end)
  end

  test "validates versions, digests, order, compatibility, and live values" do
    assert {:error, {:unsupported_fixture_version, 2, 1}} = Fixture.new(%{version: 2})

    {:ok, recorder} = Recorder.start_recording(compatibility: %{"adapter" => "fake-v1"})
    assert {:ok, :ok} = Recorder.capture(recorder, :policy, :allow, %{}, fn -> {:ok, :ok} end)
    {:ok, fixture} = Recorder.fixture(recorder)

    assert {:error, {:fixture_digest_mismatch, _expected, "sha256:bad"}} =
             fixture |> Fixture.to_map() |> Map.put("digest", "sha256:bad") |> Fixture.new()

    assert {:error, {:capability_fixture_incompatible, _, _}} =
             Recorder.start_replay(fixture, compatibility: %{"adapter" => "other"})

    assert {:error, {:invalid_replay_compatibility, :bad}} =
             Recorder.start_replay(fixture, compatibility: :bad)

    assert {:error, {:invalid_replay_redactions, [""]}} = Recorder.start_recording(redact_strings: [""])

    duplicate = fixture.entries ++ fixture.entries
    assert {:error, {:invalid_fixture_order, [1, 1]}} = Fixture.new(%{entries: duplicate})

    {:ok, unsafe} = Recorder.start_recording()

    assert {:error, {:capability_fixture_response_rejected, {:nonportable_fixture_value, :pid}}} =
             Recorder.capture(unsafe, :operation, :unsafe, %{}, fn -> {:ok, self()} end)

    [entry] = Fixture.to_map(fixture)["entries"]

    unsafe_fixture = %{
      "entries" => [Map.put(entry, "response", %{"api_key" => "raw-secret"})]
    }

    assert {:error, {:invalid_fixture_entry, _reason}} = Fixture.new(unsafe_fixture)
  end

  test "records environment lifecycle separately and marks replay evidence as recorded" do
    {:ok, recorder} = Recorder.start_recording()

    evidence = %{
      "status" => "confirmed",
      "adapter_id" => "fake",
      "backend" => "test",
      "observed_at_ms" => 10,
      "facts" => %{"isolation" => "process"}
    }

    assert {:ok, %{"resource_ref" => "env-1"}, ^evidence} =
             Environment.record(recorder, :open, %{"profile_id" => "test"}, fn ->
               {:ok, %{"resource_ref" => "env-1"}, evidence}
             end)

    {:ok, fixture} = Recorder.fixture(recorder)
    assert [%{class: "environment", action: "open"}] = fixture.entries
    {:ok, player} = Recorder.start_replay(fixture)

    assert {:ok, %{"resource_ref" => "env-1"}, replayed} =
             Environment.replay(player, :open, %{"profile_id" => "test"})

    assert replayed["facts"] == %{"isolation" => "process", "evidence_source" => "recorded", "live" => false}
    assert :ok = Recorder.finish(player)
    assert {:error, {:invalid_environment_replay_action, "destroy"}} = Environment.replay(player, :destroy, %{})
  end

  test "replays an environment cleanup failure" do
    {:ok, recorder} = Recorder.start_recording()

    assert {:error, :cleanup_failed} =
             Environment.record(recorder, :cleanup, %{"resource_ref" => "env-1"}, fn ->
               {:error, :cleanup_failed}
             end)

    {:ok, fixture} = Recorder.fixture(recorder)
    {:ok, player} = Recorder.start_replay(fixture)

    assert {:error, :cleanup_failed} =
             Environment.replay(player, :cleanup, %{"resource_ref" => "env-1"})

    assert :ok = Recorder.finish(player)
  end

  test "rejects malformed recorded enforcement evidence" do
    {:ok, recorder} = Recorder.start_recording()

    malformed = %{
      "status" => "confirmed",
      "adapter_id" => "fake",
      "backend" => "test",
      "observed_at_ms" => 10,
      "facts" => ["not", "a", "map"]
    }

    assert {:ok, ^malformed} =
             Environment.record(recorder, :close, %{"resource_ref" => "env-1"}, fn -> {:ok, malformed} end)

    {:ok, fixture} = Recorder.fixture(recorder)
    {:ok, player} = Recorder.start_replay(fixture)

    assert {:error, {:invalid_recorded_environment_evidence, _reason}} =
             Environment.replay(player, :close, %{"resource_ref" => "env-1"})
  end
end
