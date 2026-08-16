defmodule Jidoka.Adapter.ReqLLM.NormalizedStream do
  @moduledoc false

  alias Jidoka.Effect.LLMDecision
  alias Jidoka.Effect.OperationRequest
  alias Jidoka.Portable
  alias ReqLLM.StreamChunk

  @terminal_types [:finish, :cancelled, :error]
  @content_key ~s("content")

  defstruct raw_chunks: [],
            raw_size: 0,
            visible_chunks: [],
            visible_size: 0,
            reasoning_chunks: [],
            reasoning_size: 0,
            text_mode: :pending,
            mode_probe: :leading,
            scanner: %{phase: :key, key_index: 0, scanned_bytes: 0},
            terminal?: false

  @type normalized_record :: %{required(:type) => atom(), optional(atom()) => term()}

  @type t :: %__MODULE__{
          raw_chunks: [binary()],
          raw_size: non_neg_integer(),
          visible_chunks: [binary()],
          visible_size: non_neg_integer(),
          reasoning_chunks: [binary()],
          reasoning_size: non_neg_integer(),
          text_mode: :pending | :plain | :protocol,
          mode_probe: :leading | {:ticks, 1 | 2},
          scanner: map(),
          terminal?: boolean()
        }

  @doc false
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc false
  @spec raw_text(t()) :: String.t()
  def raw_text(%__MODULE__{raw_chunks: chunks}), do: chunks_to_binary(chunks)

  @doc false
  @spec scanner_stats(t()) :: %{
          raw_bytes: non_neg_integer(),
          scanned_bytes: non_neg_integer(),
          undecoded_suffix_bytes: non_neg_integer()
        }
  def scanner_stats(%__MODULE__{} = state) do
    %{
      raw_bytes: state.raw_size,
      scanned_bytes: state.scanner.scanned_bytes,
      undecoded_suffix_bytes: scanner_suffix_bytes(state)
    }
  end

  @doc false
  @spec push(t(), StreamChunk.t()) :: {t(), [normalized_record()]}
  def push(%__MODULE__{terminal?: true} = state, %StreamChunk{}), do: {state, []}

  def push(%__MODULE__{} = state, %StreamChunk{type: :content, text: text})
      when is_binary(text) do
    push_text(state, text)
  end

  def push(%__MODULE__{} = state, %StreamChunk{type: :thinking, text: text})
      when is_binary(text) and text != "" do
    state = %{
      state
      | reasoning_chunks: [text | state.reasoning_chunks],
        reasoning_size: state.reasoning_size + byte_size(text)
    }

    {state, [%{type: :reasoning_delta, delta: text}]}
  end

  def push(%__MODULE__{} = state, %StreamChunk{}), do: {state, []}

  @doc false
  @spec complete(t(), ReqLLM.Response.t(), LLMDecision.t()) :: {t(), [normalized_record()]}
  def complete(%__MODULE__{terminal?: true} = state, %ReqLLM.Response{}, %LLMDecision{}),
    do: {state, []}

  def complete(%__MODULE__{} = state, %ReqLLM.Response{} = response, %LLMDecision{} = decision) do
    {state, text_records} = complete_text(state, response, decision)
    {state, reasoning_records} = complete_reasoning(state, response)

    records =
      text_records ++
        reasoning_records ++
        tool_call_records(decision) ++
        usage_records(response) ++
        warning_records(response) ++
        [finish_record(response)]

    {%{state | terminal?: true}, records}
  end

  @doc false
  @spec fail(t(), term()) :: {t(), [normalized_record()]}
  def fail(%__MODULE__{terminal?: true} = state, _reason), do: {state, []}

  def fail(%__MODULE__{} = state, reason) do
    type = if cancelled?(reason), do: :cancelled, else: :error
    data = if type == :cancelled, do: %{finish_reason: :cancelled}, else: %{error: Portable.project(reason)}
    {%{state | terminal?: true}, [Map.put(data, :type, type)]}
  end

  @doc false
  @spec terminal?(normalized_record()) :: boolean()
  def terminal?(%{type: type}), do: type in @terminal_types
  def terminal?(_record), do: false

  defp push_text(state, ""), do: {state, []}

  defp push_text(%__MODULE__{text_mode: :plain} = state, text) do
    state = state |> append_raw(text) |> append_visible(text)
    {state, [%{type: :text_delta, delta: text}]}
  end

  defp push_text(%__MODULE__{text_mode: :protocol} = state, text) do
    state = append_raw(state, text)
    {scanner, delta} = scan_protocol(state.scanner, text)
    state = %{state | scanner: scanner} |> append_visible(delta)
    {state, delta_record(:text_delta, delta)}
  end

  defp push_text(%__MODULE__{text_mode: :pending} = state, text) do
    state = append_raw(state, text)

    case detect_text_mode(text, state.mode_probe) do
      {:pending, mode_probe} ->
        {%{state | mode_probe: mode_probe}, []}

      {:plain, _mode_probe} ->
        delta = raw_text(state)
        state = %{state | text_mode: :plain} |> append_visible(delta)
        {state, delta_record(:text_delta, delta)}

      {:protocol, _mode_probe} ->
        {scanner, delta} =
          state.raw_chunks
          |> Enum.reverse()
          |> Enum.reduce({state.scanner, ""}, fn chunk, {scanner, emitted} ->
            {scanner, delta} = scan_protocol(scanner, chunk)
            {scanner, emitted <> delta}
          end)

        state = %{state | text_mode: :protocol, scanner: scanner} |> append_visible(delta)
        {state, delta_record(:text_delta, delta)}
    end
  end

  defp detect_text_mode(text, probe), do: detect_text_mode_codepoint(String.next_codepoint(text), probe)

  defp detect_text_mode_codepoint(nil, probe), do: {:pending, probe}

  defp detect_text_mode_codepoint({codepoint, rest}, :leading) do
    cond do
      String.trim(codepoint) == "" -> detect_text_mode(rest, :leading)
      codepoint in ["{", "["] -> {:protocol, :leading}
      codepoint == "`" -> detect_text_mode(rest, {:ticks, 1})
      true -> {:plain, :leading}
    end
  end

  defp detect_text_mode_codepoint({"`", rest}, {:ticks, 1}),
    do: detect_text_mode(rest, {:ticks, 2})

  defp detect_text_mode_codepoint({"`", _rest}, {:ticks, 2}), do: {:protocol, :leading}
  defp detect_text_mode_codepoint({_codepoint, _rest}, {:ticks, _count}), do: {:plain, :leading}

  defp complete_text(state, response, decision) do
    text = response_text(response, decision)
    emit_visible_text(state, text)
  end

  defp complete_reasoning(state, response) do
    reasoning = ReqLLM.Response.thinking(response) || ""
    streamed_reasoning = chunks_to_binary(state.reasoning_chunks)

    if reasoning != "" and String.starts_with?(reasoning, streamed_reasoning) do
      delta = String.replace_prefix(reasoning, streamed_reasoning, "")

      next_state = %{
        state
        | reasoning_chunks: if(delta == "", do: state.reasoning_chunks, else: [delta | state.reasoning_chunks]),
          reasoning_size: byte_size(reasoning)
      }

      {next_state, delta_record(:reasoning_delta, delta)}
    else
      {state, []}
    end
  end

  defp response_text(_response, %LLMDecision{type: :final, content: content}) when is_binary(content),
    do: content

  defp response_text(response, %LLMDecision{metadata: metadata}) do
    Map.get(metadata, :assistant_text) || ReqLLM.Response.text(response) || ""
  end

  defp emit_visible_text(state, text) when is_binary(text) do
    visible_text = chunks_to_binary(state.visible_chunks)

    if text != visible_text and String.starts_with?(text, visible_text) do
      delta = String.replace_prefix(text, visible_text, "")
      {append_visible(state, delta), delta_record(:text_delta, delta)}
    else
      {state, []}
    end
  end

  defp delta_record(_type, ""), do: []
  defp delta_record(type, delta), do: [%{type: type, delta: delta}]

  defp tool_call_records(%LLMDecision{type: type, operations: operations})
       when type in [:operation, :operations] do
    Enum.map(operations, fn operation ->
      %{type: :tool_call, call: operation |> OperationRequest.to_payload() |> Portable.project()}
    end)
  end

  defp tool_call_records(%LLMDecision{}), do: []

  defp usage_records(%ReqLLM.Response{usage: usage}) when is_map(usage),
    do: [%{type: :usage, usage: Portable.project(usage)}]

  defp usage_records(%ReqLLM.Response{}), do: []

  defp warning_records(response) do
    response
    |> ReqLLM.Response.call_metadata()
    |> Map.get(:warnings, [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.map(&%{type: :warning, warning: &1})
  end

  defp finish_record(response) do
    %{type: :finish, finish_reason: ReqLLM.Response.finish_reason(response) || :unknown}
  end

  defp cancelled?(:llm_response_cancelled), do: true
  defp cancelled?(:cancelled), do: true
  defp cancelled?({:cancelled, _reason}), do: true
  defp cancelled?(%{details: %{cause: :cancelled}}), do: true
  defp cancelled?(_reason), do: false

  defp append_raw(state, text),
    do: %{state | raw_chunks: [text | state.raw_chunks], raw_size: state.raw_size + byte_size(text)}

  defp append_visible(state, ""), do: state

  defp append_visible(state, text),
    do: %{
      state
      | visible_chunks: [text | state.visible_chunks],
        visible_size: state.visible_size + byte_size(text)
    }

  defp chunks_to_binary(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp scan_protocol(scanner, binary) do
    scanner = Map.update!(scanner, :scanned_bytes, &(&1 + byte_size(binary)))

    {binary, scanner} =
      case scanner.phase do
        {:utf8, suffix} -> {suffix <> binary, %{scanner | phase: :value}}
        _phase -> {binary, scanner}
      end

    {scanner, emitted} = scan_protocol_bytes(binary, scanner, [])
    {scanner, emitted |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp scan_protocol_bytes(<<>>, scanner, emitted), do: {scanner, emitted}
  defp scan_protocol_bytes(_binary, %{phase: :done} = scanner, emitted), do: {scanner, emitted}

  defp scan_protocol_bytes(<<byte, rest::binary>>, %{phase: :key} = scanner, emitted) do
    index = scanner.key_index

    if byte == :binary.at(@content_key, index) do
      next_index = index + 1

      if next_index == byte_size(@content_key) do
        scan_protocol_bytes(rest, %{scanner | phase: :colon, key_index: 0}, emitted)
      else
        scan_protocol_bytes(rest, %{scanner | key_index: next_index}, emitted)
      end
    else
      next_index = if byte == :binary.first(@content_key), do: 1, else: 0
      scan_protocol_bytes(rest, %{scanner | key_index: next_index}, emitted)
    end
  end

  defp scan_protocol_bytes(<<byte, rest::binary>>, %{phase: :colon} = scanner, emitted) do
    cond do
      json_whitespace?(byte) -> scan_protocol_bytes(rest, scanner, emitted)
      byte == ?: -> scan_protocol_bytes(rest, %{scanner | phase: :quote}, emitted)
      true -> scan_protocol_bytes(rest, reset_key_scanner(scanner, byte), emitted)
    end
  end

  defp scan_protocol_bytes(<<byte, rest::binary>>, %{phase: :quote} = scanner, emitted) do
    cond do
      json_whitespace?(byte) -> scan_protocol_bytes(rest, scanner, emitted)
      byte == ?" -> scan_protocol_bytes(rest, %{scanner | phase: :value}, emitted)
      true -> scan_protocol_bytes(rest, reset_key_scanner(scanner, byte), emitted)
    end
  end

  defp scan_protocol_bytes(<<byte, rest::binary>>, %{phase: :value} = scanner, emitted)
       when byte < 0x80 do
    case byte do
      ?" -> scan_protocol_bytes(rest, %{scanner | phase: :done}, emitted)
      ?\\ -> scan_protocol_bytes(rest, %{scanner | phase: :escape}, emitted)
      byte -> scan_protocol_bytes(rest, scanner, [byte | emitted])
    end
  end

  defp scan_protocol_bytes(binary, %{phase: :value} = scanner, emitted) do
    case take_utf8(binary) do
      {:ok, codepoint, rest} -> scan_protocol_bytes(rest, scanner, [codepoint | emitted])
      :incomplete -> {%{scanner | phase: {:utf8, binary}}, emitted}
      :invalid -> {%{scanner | phase: :done}, emitted}
    end
  end

  defp scan_protocol_bytes(<<byte, rest::binary>>, %{phase: :escape} = scanner, emitted) do
    case escaped_byte(byte) do
      {:ok, decoded} -> scan_protocol_bytes(rest, %{scanner | phase: :value}, [decoded | emitted])
      :unicode -> scan_protocol_bytes(rest, %{scanner | phase: {:unicode, ""}}, emitted)
      :invalid -> {%{scanner | phase: :done}, emitted}
    end
  end

  defp scan_protocol_bytes(
         <<byte, rest::binary>>,
         %{phase: {:unicode, hex}} = scanner,
         emitted
       ) do
    if hex_digit?(byte) do
      hex = hex <> <<byte>>

      if byte_size(hex) == 4 do
        decode_unicode_escape(hex, rest, scanner, emitted)
      else
        scan_protocol_bytes(rest, %{scanner | phase: {:unicode, hex}}, emitted)
      end
    else
      {%{scanner | phase: :done}, emitted}
    end
  end

  defp reset_key_scanner(scanner, byte) do
    key_index = if byte == :binary.first(@content_key), do: 1, else: 0
    %{scanner | phase: :key, key_index: key_index}
  end

  defp json_whitespace?(byte), do: byte in [0x20, 0x09, 0x0A, 0x0D]

  defp escaped_byte(?"), do: {:ok, ?"}
  defp escaped_byte(?\\), do: {:ok, ?\\}
  defp escaped_byte(?/), do: {:ok, ?/}
  defp escaped_byte(?b), do: {:ok, ?\b}
  defp escaped_byte(?f), do: {:ok, ?\f}
  defp escaped_byte(?n), do: {:ok, ?\n}
  defp escaped_byte(?r), do: {:ok, ?\r}
  defp escaped_byte(?t), do: {:ok, ?\t}
  defp escaped_byte(?u), do: :unicode
  defp escaped_byte(_byte), do: :invalid

  defp hex_digit?(byte), do: byte in ?0..?9 or byte in ?a..?f or byte in ?A..?F

  defp decode_unicode_escape(hex, rest, scanner, emitted) do
    case String.to_integer(hex, 16) do
      codepoint when codepoint in 0xD800..0xDFFF ->
        {%{scanner | phase: :done}, emitted}

      codepoint ->
        scan_protocol_bytes(rest, %{scanner | phase: :value}, [<<codepoint::utf8>> | emitted])
    end
  rescue
    ArgumentError -> {%{scanner | phase: :done}, emitted}
  end

  defp take_utf8(<<first, _rest::binary>> = binary) do
    with {:ok, size} <- utf8_size(first),
         true <- byte_size(binary) >= size do
      <<candidate::binary-size(^size), rest::binary>> = binary

      if String.valid?(candidate), do: {:ok, candidate, rest}, else: :invalid
    else
      false -> :incomplete
      :error -> :invalid
    end
  end

  defp utf8_size(first) when first in 0xC2..0xDF, do: {:ok, 2}
  defp utf8_size(first) when first in 0xE0..0xEF, do: {:ok, 3}
  defp utf8_size(first) when first in 0xF0..0xF4, do: {:ok, 4}
  defp utf8_size(_first), do: :error

  defp scanner_suffix_bytes(%__MODULE__{text_mode: :pending, raw_size: raw_size}), do: raw_size
  defp scanner_suffix_bytes(%__MODULE__{scanner: %{phase: {:utf8, suffix}}}), do: byte_size(suffix)
  defp scanner_suffix_bytes(%__MODULE__{scanner: %{phase: {:unicode, suffix}}}), do: byte_size(suffix)
  defp scanner_suffix_bytes(%__MODULE__{}), do: 0
end
