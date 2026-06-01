defmodule Jidoka.TraceTest do
  use ExUnit.Case, async: true

  alias Jidoka.Event
  alias Jidoka.Trace
  alias Jidoka.Trace.Policy
  alias Jidoka.Trace.Sink.InMemory

  test "timeline applies sampling, omission, and redaction policy" do
    event =
      Event.build(:prompt_assembled, [],
        request_id: "turn_trace",
        data: %{
          api_key: "secret",
          prompt: "large prompt",
          visible: "ok"
        }
      )

    policy = Policy.new!(redact_keys: [:api_key], omit_keys: [:prompt])

    assert [
             %{
               event: :prompt_assembled,
               data: %{api_key: "[REDACTED]", visible: "ok"}
             }
           ] = Trace.timeline([event], policy: policy)

    assert [] = Trace.timeline([event], sample_rate: 0.0)
    assert [] = Trace.timeline([event], policy: Policy.new!(sample_rate: 0.0))
    assert [] = Trace.timeline([event], policy: Policy.new!(enabled: false))
  end

  test "in-memory trace sink records projected entries" do
    {:ok, pid} = InMemory.start_link()

    event = Event.build(:turn_finished, [], request_id: "turn_sink")
    policy = Policy.new!(redact_keys: [], omit_keys: [])

    assert :ok = Trace.record([event], {InMemory, pid: pid}, policy: policy)

    assert [%{event: :turn_finished, request_id: "turn_sink", projection: :trace}] =
             InMemory.list(pid)

    assert :ok = InMemory.clear(pid)
    assert [] = InMemory.list(pid)
  end

  test "trace policy and sink errors stay explicit data" do
    assert {:ok, %Policy{enabled: true, sample_rate: 1.0}} = Policy.from_input(nil)
    assert {:ok, %Policy{enabled: true}} = Policy.from_input(Policy.new!())
    assert {:error, _reason} = Policy.new(sample_rate: 2.0)
    assert "api_key" in Policy.default_redact_keys()
    assert "prompt" in Policy.default_omit_keys()

    assert %{
             enabled: false,
             sample_rate: 0.5,
             redact_keys: ["secret"],
             omit_keys: ["payload"]
           } =
             Jidoka.project(
               Policy.new!(
                 enabled: false,
                 sample_rate: 0.5,
                 redact_keys: [:secret],
                 omit_keys: [:payload]
               )
             )

    event = Event.build(:turn_finished, [], request_id: "turn_sink_error")

    assert {:error, :missing_trace_sink_pid} =
             Trace.record([event], InMemory, policy: Policy.new!())

    assert {:error, _reason} = Trace.record([event], InMemory, sample_rate: 2.0)

    assert_raise ArgumentError, ~r/invalid trace policy/, fn ->
      Trace.timeline([event], sample_rate: 2.0)
    end

    assert {:error, {:invalid_trace_sink, :not_a_sink}} =
             Jidoka.Trace.Sink.record(:not_a_sink, [], Policy.new!())
  end

  test "trace projection handles map events, fallback values, map policies, and disabled input" do
    map_event = %{
      event: :custom_trace,
      request_id: "turn_map",
      data: %{token: "secret", prompt: "omit", visible: [%{password: "hide", value: "ok"}]}
    }

    assert [
             %{
               seq: 0,
               projection: :trace,
               event: :custom_trace,
               data: %{token: "[REDACTED]", visible: [%{password: "[REDACTED]", value: "ok"}]}
             },
             %{
               seq: 1,
               projection: :trace,
               event: :unknown_event,
               data: %{value: :loose_event}
             }
           ] =
             Trace.timeline([map_event, :loose_event], %{
               "trace_policy" => %{
                 "redact_keys" => ["token", "password"],
                 "omit_keys" => ["prompt"]
               }
             })

    assert [] = Trace.timeline([map_event], %{policy: %{enabled: false}})
    assert [] = Trace.timeline(:not_events, %{})

    assert %{secret: "[REDACTED]", nested: %{token: "[REDACTED]"}, keep: "ok"} =
             Trace.redact(
               %{secret: "hide", nested: %{token: "hide"}, keep: "ok"},
               redact_keys: [:secret, :token],
               omit_keys: []
             )

    assert %{secret: "hide"} = Trace.redact(%{secret: "hide"}, sample_rate: 2.0)
  end
end
