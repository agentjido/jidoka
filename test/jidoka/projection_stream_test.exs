defmodule Jidoka.ProjectionStreamTest do
  use ExUnit.Case, async: true

  alias Jidoka.Event

  test "the root facade projects known, terminal, error, and unknown event data" do
    events = [
      Event.build(:turn_started, [], request_id: "req-1", seq: 0, agent_id: "agent-1", data: %{turn_id: "trn-1"}),
      Event.build(:llm_delta, [], request_id: "req-1", seq: 1, data: %{text: "Hello", extra: "bounded"}),
      Event.build(:turn_failed, [], request_id: "req-1", seq: 2, error: {:boom, :policy_denied})
    ]

    assert {:ok, projected} = Jidoka.project_events(events)
    assert Enum.map(projected, & &1.seq) == [0, 1, 2]
    assert Enum.map(projected, & &1.request_id) == ["req-1", "req-1", "req-1"]
    assert hd(projected).turn_id == "trn-1"
    assert hd(projected).agent_id == "agent-1"
    assert List.last(projected).terminal? == true
    assert Enum.at(projected, 1).data["text"] == "Hello"
    assert Enum.at(projected, 1).data["unknown"]["extra"] == "bounded"
    assert {:ok, _} = Jason.encode(projected)
  end

  test "sensitive values are redacted and runtime values do not cross the facade" do
    event =
      Event.build(:effect_completed, [],
        request_id: "req-2",
        seq: 0,
        data: %{
          token: "sk-secret",
          owner: self(),
          ref: make_ref(),
          fun: fn -> :ok end
        }
      )

    assert {:ok, projected} = Jidoka.project_events(event)
    encoded = inspect(projected)
    refute encoded =~ "sk-secret"
    refute encoded =~ "#PID"
    refute encoded =~ "#Reference"
    assert projected.data["token"] == "[REDACTED]"
    refute Map.has_key?(projected.data, "owner")
    refute Map.has_key?(projected.data, "fun")
    assert {:ok, _} = Jason.encode(projected)
  end

  test "oversized unknown data is rejected" do
    event =
      Event.build(:llm_delta, [],
        request_id: "req-3",
        seq: 0,
        data: %{blob: String.duplicate("x", 5_000)}
      )

    assert {:error, :unknown_projection_overflow} = Jidoka.project_events(event)
  end

  test "events without a request identity are rejected" do
    event = Event.build(:turn_started, [], seq: 0)
    assert {:error, :missing_request_id} = Jidoka.project_events([event])
  end
end
