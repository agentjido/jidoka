defmodule JidokaTest.ObservabilitySmokeTest do
  use JidokaTest.Support.Case, async: false

  alias Jidoka.Session
  alias JidokaTest.ChatAgent

  @events [
    [:jidoka, :guardrail, :event],
    [:jidoka, :control, :event],
    [:jidoka, :hook, :event]
  ]

  test "session chat emits inspectable observability data without a provider" do
    session =
      Session.new!(
        agent: ChatAgent,
        id: unique_id("observability-session"),
        context: %{tenant: "acme"}
      )

    handler_id = :"jidoka-observability-smoke-#{System.unique_integer([:positive])}"
    parent = self()

    :ok = :telemetry.attach_many(handler_id, @events, &__MODULE__.capture_event/4, parent)

    guardrail = fn input ->
      send(parent, {:guardrail_input, input.request_id, input.context})
      {:interrupt, %{kind: :approval, message: "Stop before provider", data: %{reason: "smoke"}}}
    end

    try do
      assert {:interrupt, %Jidoka.Interrupt{kind: :approval, message: "Stop before provider"}} =
               Jidoka.chat(session, "hello", context: %{channel: "support"}, guardrails: [input: guardrail])

      assert_receive {:guardrail_input, request_id, context}
      assert Jidoka.Context.strip_internal(context) == %{session: session.id, tenant: "acme", channel: "support"}

      events = collect_events()

      assert Enum.any?(events, fn
               {[:jidoka, :guardrail, :event], _measurements, %{event: :start}} -> true
               _event -> false
             end)

      assert Enum.any?(events, fn
               {[:jidoka, :guardrail, :event], _measurements, %{event: :interrupt} = metadata} ->
                 metadata.agent_id == session.agent_id and
                   metadata.request_id == request_id and
                   metadata.session_id == session.id and
                   metadata.conversation_id == session.conversation_id

               _event ->
                 false
             end)

      assert {:ok, request_summary} = Jidoka.inspect_request(session)
      assert request_summary.request_id == request_id
      assert request_summary.input_message == "hello"
      assert request_summary.status == :failed

      assert {:ok, trace} = Jidoka.inspect_trace(session, request_id)
      assert trace.agent_id == session.agent_id
      assert trace.request_id == request_id
      assert trace.summary.guardrail_events >= 2

      assert Enum.any?(trace.events, &(&1.category == :guardrail and &1.event == :interrupt))
    after
      :telemetry.detach(handler_id)
      stop_session_agent(session)
    end
  end

  def capture_event(event_name, measurements, metadata, parent) do
    send(parent, {:jidoka_observability_event, event_name, measurements, metadata})
  end

  defp collect_events(acc \\ []) do
    receive do
      {:jidoka_observability_event, event_name, measurements, metadata} ->
        collect_events([{event_name, measurements, metadata} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp stop_session_agent(%Session{} = session) do
    case Session.whereis(session) do
      nil -> :ok
      pid -> Jidoka.stop_agent(pid)
    end
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
