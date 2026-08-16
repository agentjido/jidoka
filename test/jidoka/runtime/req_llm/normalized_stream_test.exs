defmodule Jidoka.Adapter.ReqLLM.NormalizedStreamTest do
  use ExUnit.Case, async: true

  alias Jidoka.Adapter.ReqLLM.NormalizedStream
  alias Jidoka.Effect.LLMDecision
  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response
  alias ReqLLM.StreamChunk

  test "streamed and non-streamed responses have the same completed record" do
    response = response("hello", "check", usage: %{input_tokens: 3}, warnings: ["retry"])
    decision = LLMDecision.final("hello")

    stream_state = NormalizedStream.new()
    {stream_state, first} = NormalizedStream.push(stream_state, StreamChunk.text("he"))
    {stream_state, reasoning} = NormalizedStream.push(stream_state, StreamChunk.thinking("check"))
    {stream_state, second} = NormalizedStream.push(stream_state, StreamChunk.text("llo"))
    {_stream_state, final} = NormalizedStream.complete(stream_state, response, decision)

    {_non_stream_state, non_stream_records} =
      NormalizedStream.complete(NormalizedStream.new(), response, decision)

    stream_records = first ++ reasoning ++ second ++ final

    assert collapse_deltas(stream_records) == collapse_deltas(non_stream_records)

    assert Enum.map(non_stream_records, & &1.type) == [
             :text_delta,
             :reasoning_delta,
             :usage,
             :warning,
             :finish
           ]
  end

  test "does not emit a runnable tool call until the final arguments are validated" do
    partial = StreamChunk.tool_call("coding.read", %{}, %{id: "call-1", index: 0})
    state = NormalizedStream.new()

    assert {state, []} = NormalizedStream.push(state, partial)

    decision =
      LLMDecision.operation("coding.read", %{"path" => "lib/jidoka.ex"},
        provider_call_id: "call-1",
        provider_metadata: %{provider_tool_name: "coding_read"}
      )

    {_state, records} = NormalizedStream.complete(state, response("", ""), decision)

    assert [tool_call, terminal] = records
    assert tool_call.type == :tool_call
    assert tool_call.call.name == "coding.read"
    assert tool_call.call.arguments == %{"path" => "lib/jidoka.ex"}
    assert tool_call.call.provider_call_id == "call-1"
    assert terminal == %{type: :finish, finish_reason: :stop}
  end

  test "projects only the visible content from the JSON protocol" do
    state = NormalizedStream.new()

    {state, first} =
      NormalizedStream.push(state, StreamChunk.text(~s({"type":"final","content":"hel)))

    {state, second} = NormalizedStream.push(state, StreamChunk.text(~s(lo\\nworld"})))

    assert first ++ second == [
             %{type: :text_delta, delta: "hel"},
             %{type: :text_delta, delta: "lo\nworld"}
           ]

    {_state, records} =
      NormalizedStream.complete(state, response("hello\nworld", ""), LLMDecision.final("hello\nworld"))

    assert records == [%{type: :finish, finish_reason: :stop}]
  end

  test "one-byte chunks preserve escaped protocol content and event order" do
    wire = ~s(  ```json\n{"type":"final","content":"héllo\\n\\u263A"}\n```)

    {chunked_state, chunked_records} = push_chunks([wire])
    {byte_state, byte_records} = push_chunks(for <<byte <- wire>>, do: <<byte>>)

    assert text_from_records(chunked_records) == "héllo\n☺"
    assert text_from_records(byte_records) == "héllo\n☺"
    assert NormalizedStream.raw_text(byte_state) == wire

    response = response("héllo\n☺", "")
    decision = LLMDecision.final("héllo\n☺")
    {_chunked_state, chunked_completion} = NormalizedStream.complete(chunked_state, response, decision)
    {_byte_state, byte_completion} = NormalizedStream.complete(byte_state, response, decision)

    assert chunked_completion == byte_completion
    assert chunked_completion == [%{type: :finish, finish_reason: :stop}]
  end

  test "large protocol streams scan every input byte once" do
    content = String.duplicate("x", 20_000)
    wire = ~s({"type":"final","content":"#{content}"})
    {state, records} = push_chunks(for <<byte <- wire>>, do: <<byte>>)

    assert text_from_records(records) == content
    assert NormalizedStream.raw_text(state) == wire

    assert %{
             raw_bytes: bytes,
             scanned_bytes: bytes,
             undecoded_suffix_bytes: 0
           } = NormalizedStream.scanner_stats(state)

    assert bytes == byte_size(wire)
  end

  test "an incomplete escape keeps only its suffix and a provider error remains terminal" do
    wire = ~s({"type":"final","content":"ok\\u26)
    {state, records} = push_chunks(for <<byte <- wire>>, do: <<byte>>)

    assert text_from_records(records) == "ok"
    assert %{undecoded_suffix_bytes: 2} = NormalizedStream.scanner_stats(state)

    {_state, error_records} = NormalizedStream.fail(state, :provider_disconnected)

    assert records ++ error_records ==
             Enum.filter(records, &(&1.type == :text_delta)) ++
               [%{type: :error, error: :provider_disconnected}]

    assert Enum.count(records ++ error_records, &NormalizedStream.terminal?/1) == 1
  end

  test "cancellation and errors close the normalized stream exactly once" do
    state = NormalizedStream.new()
    {state, records} = NormalizedStream.fail(state, :llm_response_cancelled)

    assert records == [%{type: :cancelled, finish_reason: :cancelled}]
    assert Enum.count(records, &NormalizedStream.terminal?/1) == 1
    assert {^state, []} = NormalizedStream.fail(state, :another_error)

    {_state, error_records} = NormalizedStream.fail(NormalizedStream.new(), :transport_failed)
    assert [%{type: :error, error: :transport_failed}] = error_records
    assert Enum.count(error_records, &NormalizedStream.terminal?/1) == 1
  end

  defp response(text, thinking, opts \\ []) do
    parts = [ContentPart.text(text), ContentPart.thinking(thinking)]

    %Response{
      id: "response-1",
      model: "test:model",
      context: Context.new([]),
      message: Context.assistant(parts),
      usage: Keyword.get(opts, :usage),
      finish_reason: Keyword.get(opts, :finish_reason, :stop),
      provider_meta: %{warnings: Keyword.get(opts, :warnings, [])}
    }
  end

  defp collapse_deltas(records) do
    {text, reasoning, other} =
      Enum.reduce(records, {"", "", []}, fn
        %{type: :text_delta, delta: delta}, {text, reasoning, other} ->
          {text <> delta, reasoning, other}

        %{type: :reasoning_delta, delta: delta}, {text, reasoning, other} ->
          {text, reasoning <> delta, other}

        record, {text, reasoning, other} ->
          {text, reasoning, other ++ [record]}
      end)

    [%{type: :text_delta, delta: text}, %{type: :reasoning_delta, delta: reasoning} | other]
  end

  defp push_chunks(chunks) do
    {state, reversed_records} =
      Enum.reduce(chunks, {NormalizedStream.new(), []}, fn chunk, {state, records} ->
        {state, emitted} = NormalizedStream.push(state, StreamChunk.text(chunk))
        {state, Enum.reverse(emitted, records)}
      end)

    {state, Enum.reverse(reversed_records)}
  end

  defp text_from_records(records) do
    records
    |> Enum.flat_map(fn
      %{type: :text_delta, delta: delta} -> [delta]
      _record -> []
    end)
    |> IO.iodata_to_binary()
  end
end
