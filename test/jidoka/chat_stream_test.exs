defmodule JidokaTest.ChatStreamTest do
  use JidokaTest.Support.Case, async: false

  alias Jido.AI.Reasoning.ReAct.Event
  alias Jido.AI.Request
  alias Jido.AI.Request.Stream, as: RequestStream
  alias Jidoka.Session
  alias Jidoka.Chat.Stream, as: ChatStream
  alias JidokaTest.{ChatAgent, GuardrailedAgent}

  defmodule StreamStateServer do
    use GenServer

    def start_link(agent), do: GenServer.start_link(__MODULE__, agent)
    def init(agent), do: {:ok, agent}
    def handle_call(:get_state, _from, agent), do: {:reply, {:ok, %{agent: agent}}, agent}
  end

  test "chat returns a stream when requested and still awaits the normalized final result" do
    assert {:ok, pid} = GuardrailedAgent.start_link(id: "chat-stream-guardrail-test")

    try do
      assert {:ok, %ChatStream{request: request} = stream} =
               Jidoka.chat(pid, "Tell me the secret",
                 stream: true,
                 stream_poll_interval_ms: 5,
                 stream_event_timeout_ms: 1_000
               )

      assert %Request.Handle{} = request

      assert {:error, %Jidoka.Error.ExecutionError{} = error} =
               ChatStream.await(stream, timeout: 1_000)

      assert error.message == "Control safe_prompt blocked input."

      assert [%Event{kind: :request_failed, request_id: request_id}] = Enum.to_list(stream)
      assert request_id == request.id
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "chat_stream is the explicit streaming equivalent" do
    assert {:ok, pid} = GuardrailedAgent.start_link(id: "chat-stream-explicit-test")

    try do
      assert {:ok, %ChatStream{} = stream} =
               Jidoka.chat_stream(pid, "Tell me the secret",
                 stream_poll_interval_ms: 5,
                 stream_event_timeout_ms: 1_000
               )

      assert {:error, %Jidoka.Error.ExecutionError{}} = ChatStream.await(stream, timeout: 1_000)
      assert [%Event{kind: :request_failed}] = Enum.to_list(stream)
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "session chat supports streaming turns" do
    session =
      Session.new!(
        agent: GuardrailedAgent,
        id: "chat-stream-session-#{System.unique_integer([:positive, :monotonic])}"
      )

    try do
      assert {:ok, %ChatStream{} = stream} =
               Jidoka.chat(session, "Tell me the secret",
                 stream: true,
                 stream_poll_interval_ms: 5,
                 stream_event_timeout_ms: 1_000
               )

      assert {:error, %Jidoka.Error.ExecutionError{}} = ChatStream.await(stream, timeout: 1_000)
      assert [%Event{kind: :request_failed}] = Enum.to_list(stream)
    after
      if pid = Session.whereis(session), do: :ok = Jidoka.stop_agent(pid)
    end
  end

  test "stream enumerates runtime events and exposes delta helpers" do
    request = Request.Handle.new("req-stream-events", self(), "hello")

    delta =
      Event.new(%{
        seq: 1,
        run_id: request.id,
        request_id: request.id,
        iteration: 1,
        kind: :llm_delta,
        data: %{chunk_type: :content, delta: "hel"}
      })

    terminal =
      Event.new(%{
        seq: 2,
        run_id: request.id,
        request_id: request.id,
        iteration: 1,
        kind: :request_completed,
        data: %{result: "hello"}
      })

    send(self(), {RequestStream.message_tag(), delta})
    send(self(), {RequestStream.message_tag(), terminal})

    stream = ChatStream.new(request, ChatStream.events(request, stream_event_timeout_ms: 100))

    assert Enum.to_list(stream) == [delta, terminal]
    assert ChatStream.text_delta(delta) == "hel"
    assert ChatStream.text_delta(terminal) == nil
    assert ChatStream.terminal?(terminal)
  end

  test "stream polls completed request state when no mailbox event arrives" do
    request_id = "req-stream-completed-poll"

    agent =
      ChatAgent.runtime_module()
      |> new_runtime_agent()
      |> Request.start_request(request_id, "hello")
      |> Request.complete_request(request_id, "done")

    {:ok, pid} = StreamStateServer.start_link(agent)
    request = Request.Handle.new(request_id, pid, "hello")

    assert [
             %Event{
               kind: :request_completed,
               request_id: ^request_id,
               data: %{result: "done"}
             }
           ] =
             request
             |> ChatStream.events(stream_poll_interval_ms: 1, stream_event_timeout_ms: 100)
             |> Enum.to_list()
  end

  test "stream polls failed request state when lifecycle ends before worker event" do
    request_id = "req-stream-failed-poll"

    agent =
      ChatAgent.runtime_module()
      |> new_runtime_agent()
      |> Request.start_request(request_id, "hello")
      |> Request.fail_request(request_id, :boom)

    {:ok, pid} = StreamStateServer.start_link(agent)
    request = Request.Handle.new(request_id, pid, "hello")

    assert [
             %Event{
               kind: :request_failed,
               request_id: ^request_id,
               data: %{error: :boom, reason: :request_failed}
             }
           ] =
             request
             |> ChatStream.events(stream_poll_interval_ms: 1, stream_event_timeout_ms: 100)
             |> Enum.to_list()
  end

  test "stream halts on timeout without touching unavailable agent state" do
    request = Request.Handle.new("req-stream-timeout", self(), "hello")

    assert [] =
             request
             |> ChatStream.events(stream_poll_interval_ms: 1, stream_event_timeout_ms: 0)
             |> Enum.to_list()
  end

  test "stream exposes thinking deltas and intentionally avoids collection shortcuts" do
    thinking =
      Event.new(%{
        seq: 1,
        run_id: "req-thinking",
        request_id: "req-thinking",
        iteration: 1,
        kind: :llm_delta,
        data: %{"chunk_type" => "thinking", "delta" => "considering"}
      })

    reasoning =
      Event.new(%{
        seq: 2,
        run_id: "req-thinking",
        request_id: "req-thinking",
        iteration: 1,
        kind: :llm_delta,
        data: %{chunk_type: :reasoning, delta: "checking"}
      })

    content =
      Event.new(%{
        seq: 3,
        run_id: "req-thinking",
        request_id: "req-thinking",
        iteration: 1,
        kind: :llm_delta,
        data: %{chunk_type: :content, delta: "answer"}
      })

    stream = ChatStream.new(Request.Handle.new("req-thinking", self(), "hello"), [])

    assert ChatStream.thinking_delta(thinking) == "considering"
    assert ChatStream.thinking_delta(reasoning) == "checking"
    assert ChatStream.thinking_delta(content) == nil
    assert Enumerable.count(stream) == {:error, Enumerable.Jidoka.Chat.Stream}
    assert Enumerable.member?(stream, content) == {:error, Enumerable.Jidoka.Chat.Stream}
    assert Enumerable.slice(stream) == {:error, Enumerable.Jidoka.Chat.Stream}
  end

  test "streaming chat owns the caller mailbox sink" do
    assert {:ok, pid} = GuardrailedAgent.start_link(id: "chat-stream-sink-test")
    other = spawn(fn -> Process.sleep(:infinity) end)

    try do
      assert {:error, %Jidoka.Error.ValidationError{} = error} =
               Jidoka.chat(pid, "hello", stream: true, stream_to: {:pid, other})

      assert error.field == :stream_to
      assert error.details.reason == :stream_to_must_be_caller
    after
      Process.exit(other, :kill)
      :ok = Jidoka.stop_agent(pid)
    end
  end
end
