defmodule Jidoka.Adapter.ReqLLM.NormalizedStream do
  @moduledoc false

  alias Jidoka.Effect.LLMDecision
  alias Jidoka.Effect.OperationRequest
  alias Jidoka.Portable
  alias ReqLLM.StreamChunk

  @terminal_types [:finish, :cancelled, :error]

  defstruct raw_text: "",
            visible_text: "",
            reasoning: "",
            text_mode: :pending,
            terminal?: false

  @type normalized_record :: %{required(:type) => atom(), optional(atom()) => term()}

  @type t :: %__MODULE__{
          raw_text: String.t(),
          visible_text: String.t(),
          reasoning: String.t(),
          text_mode: :pending | :plain | :protocol,
          terminal?: boolean()
        }

  @doc false
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc false
  @spec push(t(), StreamChunk.t()) :: {t(), [normalized_record()]}
  def push(%__MODULE__{terminal?: true} = state, %StreamChunk{}), do: {state, []}

  def push(%__MODULE__{} = state, %StreamChunk{type: :content, text: text})
      when is_binary(text) do
    push_text(state, text)
  end

  def push(%__MODULE__{} = state, %StreamChunk{type: :thinking, text: text})
      when is_binary(text) and text != "" do
    {%{state | reasoning: state.reasoning <> text}, [%{type: :reasoning_delta, delta: text}]}
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
    {%{state | raw_text: state.raw_text <> text, visible_text: state.visible_text <> text},
     [%{type: :text_delta, delta: text}]}
  end

  defp push_text(%__MODULE__{} = state, text) do
    raw_text = state.raw_text <> text
    mode = detect_text_mode(state.text_mode, raw_text)
    state = %{state | raw_text: raw_text, text_mode: mode}

    case mode do
      :plain -> emit_visible_text(state, raw_text)
      :protocol -> emit_visible_text(state, content_prefix(raw_text))
      :pending -> {state, []}
    end
  end

  defp detect_text_mode(mode, _raw) when mode in [:plain, :protocol], do: mode

  defp detect_text_mode(:pending, raw) do
    trimmed = String.trim_leading(raw)

    cond do
      trimmed == "" -> :pending
      String.starts_with?(trimmed, "{") -> :protocol
      String.starts_with?(trimmed, "[") -> :protocol
      String.starts_with?(trimmed, "```") -> :protocol
      String.starts_with?("```", trimmed) -> :pending
      true -> :plain
    end
  end

  defp complete_text(state, response, decision) do
    text = response_text(response, decision)
    emit_visible_text(state, text)
  end

  defp complete_reasoning(state, response) do
    reasoning = ReqLLM.Response.thinking(response) || ""

    if reasoning != "" and String.starts_with?(reasoning, state.reasoning) do
      delta = String.replace_prefix(reasoning, state.reasoning, "")
      next_state = %{state | reasoning: reasoning}
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

  defp emit_visible_text(state, nil), do: {state, []}

  defp emit_visible_text(state, text) when is_binary(text) do
    if text != state.visible_text and String.starts_with?(text, state.visible_text) do
      delta = String.replace_prefix(text, state.visible_text, "")
      {%{state | visible_text: text}, delta_record(:text_delta, delta)}
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

  defp content_prefix(raw) when is_binary(raw) do
    case Regex.run(~r/"content"\s*:\s*"/, raw, return: :index) do
      [{start, length}] ->
        offset = start + length
        binary_part(raw, offset, byte_size(raw) - offset) |> decode_json_string_prefix()

      _other ->
        nil
    end
  end

  defp decode_json_string_prefix(binary), do: decode_json_string_prefix(binary, [])

  defp decode_json_string_prefix(<<"\"", _rest::binary>>, acc), do: acc_to_binary(acc)

  defp decode_json_string_prefix(<<"\\\"", rest::binary>>, acc),
    do: decode_json_string_prefix(rest, [?\" | acc])

  defp decode_json_string_prefix(<<"\\\\", rest::binary>>, acc),
    do: decode_json_string_prefix(rest, [?\\ | acc])

  defp decode_json_string_prefix(<<"\\/", rest::binary>>, acc),
    do: decode_json_string_prefix(rest, [?/ | acc])

  defp decode_json_string_prefix(<<"\\b", rest::binary>>, acc),
    do: decode_json_string_prefix(rest, [?\b | acc])

  defp decode_json_string_prefix(<<"\\f", rest::binary>>, acc),
    do: decode_json_string_prefix(rest, [?\f | acc])

  defp decode_json_string_prefix(<<"\\n", rest::binary>>, acc),
    do: decode_json_string_prefix(rest, [?\n | acc])

  defp decode_json_string_prefix(<<"\\r", rest::binary>>, acc),
    do: decode_json_string_prefix(rest, [?\r | acc])

  defp decode_json_string_prefix(<<"\\t", rest::binary>>, acc),
    do: decode_json_string_prefix(rest, [?\t | acc])

  defp decode_json_string_prefix(<<"\\u", hex::binary-size(4), rest::binary>>, acc) do
    if String.match?(hex, ~r/\A[0-9a-fA-F]{4}\z/) do
      decode_unicode_escape(hex, rest, acc)
    else
      acc_to_binary(acc)
    end
  end

  defp decode_json_string_prefix(<<"\\", _rest::binary>>, acc), do: acc_to_binary(acc)

  defp decode_json_string_prefix(<<char::utf8, rest::binary>>, acc),
    do: decode_json_string_prefix(rest, [<<char::utf8>> | acc])

  defp decode_json_string_prefix(<<>>, acc), do: acc_to_binary(acc)

  defp acc_to_binary(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp decode_unicode_escape(hex, rest, acc) do
    case String.to_integer(hex, 16) do
      codepoint when codepoint in 0xD800..0xDFFF -> acc_to_binary(acc)
      codepoint -> decode_json_string_prefix(rest, [<<codepoint::utf8>> | acc])
    end
  rescue
    ArgumentError -> acc_to_binary(acc)
  end
end
