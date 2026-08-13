defmodule Jidoka.Adapter.ReqLLM do
  @moduledoc """
  ReqLLM runtime support for Jidoka's LLM effect boundary.

  This is an advanced extension seam. Normal application calls use the default
  ReqLLM capability through `Jidoka.chat/3` or `Jidoka.turn/3`.

  The runtime uses a constrained JSON protocol instead of native provider
  tool-calling. That keeps Jidoka's Runic spine provider-neutral while still
  letting a real model choose between final answers and operation calls.
  """

  alias Jidoka.Agent.Spec.Generation
  alias Jidoka.Config
  alias Jidoka.Effect
  alias Jidoka.Event
  alias Jidoka.Adapter.ReqLLM.PromptAdapter
  alias Jidoka.Adapter.ReqLLM.ResponseAdapter
  alias Jidoka.Adapter.ReqLLM.ToolProjection
  alias Jidoka.Runtime.EventDispatcher
  alias Jidoka.Schema

  @type option ::
          {:model, ReqLLM.model_input()}
          | {:temperature, number()}
          | {:max_tokens, pos_integer()}
          | {:timeout, timeout()}
          | {:receive_timeout, timeout()}
          | {:provider_options, map()}
          | {:cache, term()}
          | {:api_key, String.t()}
          | {:stream, boolean()}
          | {:stream_to, pid() | {:pid, pid()}}
          | {:on_event, (Event.t() -> term())}

  @doc """
  Returns an LLM function suitable for `Jidoka.turn/3`.

      llm = Jidoka.Adapter.ReqLLM.llm(model: "openai:gpt-4o-mini", temperature: 0.0)
      Jidoka.turn(agent, "Use the available tool.", llm: llm, operations: ops)
  """
  @spec llm([option()]) :: Jidoka.Runtime.Capabilities.llm_capability()
  def llm(opts \\ []) when is_list(opts) do
    fn %Effect.Intent{} = intent, %Effect.Journal{} = journal, %Jidoka.Context{} ->
      generate(intent, journal, opts)
    end
  end

  @doc false
  @spec generate(Effect.Intent.t(), Effect.Journal.t(), [option()]) ::
          {:ok, Effect.LLMDecision.t()} | {:error, term()}
  def generate(%Effect.Intent{kind: :llm, payload: payload} = intent, _journal, opts) do
    with {:ok, model} <- fetch_model(payload, opts),
         {:ok, messages} <- build_messages(payload),
         {:ok, tools} <- tools(payload) do
      llm_opts =
        payload
        |> generation_opts()
        |> Keyword.merge(provider_opts(opts))
        |> put_tools(tools)

      generate_response(model, messages, llm_opts, intent, opts)
    end
  end

  def generate(%Effect.Intent{kind: kind}, _journal, _opts),
    do: {:error, {:unsupported_effect_kind, kind}}

  @doc false
  @spec messages(map()) :: {:ok, [ReqLLM.Message.t()]} | {:error, term()}
  def messages(payload_or_prompt) when is_map(payload_or_prompt) do
    case Schema.fetch_key(payload_or_prompt, :prompt) do
      {:ok, prompt} when is_map(prompt) -> PromptAdapter.build(prompt)
      {:ok, prompt} -> {:error, {:invalid_prompt_payload, prompt}}
      :error -> PromptAdapter.build(payload_or_prompt)
    end
  end

  @doc false
  @spec tools(map()) :: {:ok, [ReqLLM.Tool.t()]} | {:error, term()}
  def tools(payload_or_prompt) when is_map(payload_or_prompt) do
    case Schema.fetch_key(payload_or_prompt, :prompt) do
      {:ok, prompt} when is_map(prompt) -> ToolProjection.from_prompt(prompt)
      {:ok, prompt} -> {:error, {:invalid_prompt_payload, prompt}}
      :error -> ToolProjection.from_prompt(payload_or_prompt)
    end
  end

  defp fetch_model(payload, opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model} ->
        Config.normalize_model_spec(model)

      :error ->
        case Schema.fetch_key(payload, :model) do
          {:ok, model} ->
            Config.normalize_model_spec(model)

          :error ->
            {:ok, Config.default_model()}
        end
    end
  end

  defp generation_opts(payload) do
    payload
    |> Schema.get_key(:generation)
    |> Generation.to_req_llm_opts()
  end

  defp build_messages(payload) when is_map(payload) do
    case Schema.fetch_key(payload, :prompt) do
      {:ok, _prompt} -> messages(payload)
      :error -> {:error, {:missing_prompt_payload, payload}}
    end
  end

  defp provider_opts(opts) do
    Keyword.drop(opts, [:model, :stream, :stream_to, :on_event, :tools])
  end

  defp put_tools(opts, []), do: Keyword.delete(opts, :tools)
  defp put_tools(opts, tools), do: Keyword.put(opts, :tools, tools)

  defp generate_response(model, messages, llm_opts, %Effect.Intent{} = intent, opts) do
    if stream_enabled?(opts) do
      generate_streaming_response(model, messages, llm_opts, intent, opts)
    else
      generate_text_response(model, messages, llm_opts)
    end
  end

  defp generate_text_response(model, messages, llm_opts) do
    with {:ok, response} <- ReqLLM.Generation.generate_text(model, messages, llm_opts) do
      decision(response, model)
    end
  end

  defp generate_streaming_response(model, messages, llm_opts, %Effect.Intent{} = intent, opts) do
    stream_state_key = {__MODULE__, :stream_state, make_ref()}
    Process.put(stream_state_key, %{raw: "", content: "", seq: 0})

    result =
      with {:ok, stream_response} <- ReqLLM.Generation.stream_text(model, messages, llm_opts),
           {:ok, response} <-
             ReqLLM.StreamResponse.process_stream(
               stream_response,
               on_result: &handle_stream_content_delta(stream_state_key, intent, opts, &1),
               on_thinking: &handle_stream_thinking_delta(stream_state_key, intent, opts, &1)
             ),
           text <- response_text(stream_state_key, response),
           {:ok, decision} <- ResponseAdapter.decision(response, model, text) do
        emit_remaining_final_delta(stream_state_key, intent, decision, opts)
        {:ok, decision}
      end

    Process.delete(stream_state_key)
    result
  end

  @doc false
  @spec decision(ReqLLM.Response.t(), LLMDB.Model.t() | nil) ::
          {:ok, Effect.LLMDecision.t()} | {:error, term()}
  def decision(response, model \\ nil)

  def decision(%ReqLLM.Response{} = response, model) do
    ResponseAdapter.decision(response, model)
  end

  defp response_text(stream_state_key, response) do
    text = ReqLLM.Response.text(response)
    state = Process.get(stream_state_key, %{raw: ""})

    cond do
      is_binary(text) and String.trim(text) != "" -> text
      is_binary(state.raw) and String.trim(state.raw) != "" -> state.raw
      true -> text
    end
  end

  defp stream_enabled?(opts) do
    Keyword.get(opts, :stream) == true or Keyword.has_key?(opts, :stream_to) or
      Keyword.has_key?(opts, :on_event)
  end

  defp handle_stream_content_delta(stream_state_key, %Effect.Intent{} = intent, opts, delta)
       when is_binary(delta) do
    state = Process.get(stream_state_key, %{raw: "", content: "", seq: 0})
    raw = state.raw <> delta

    state =
      case content_prefix(raw) do
        content when is_binary(content) ->
          emit_new_content(intent, opts, %{state | raw: raw}, content)

        _other ->
          %{state | raw: raw}
      end

    Process.put(stream_state_key, state)
  end

  defp handle_stream_thinking_delta(stream_state_key, %Effect.Intent{} = intent, opts, delta)
       when is_binary(delta) and delta != "" do
    state = Process.get(stream_state_key, %{raw: "", content: "", seq: 0})
    emit_delta(intent, opts, :thinking, delta, state.seq)
    Process.put(stream_state_key, %{state | seq: state.seq + 1})
  end

  defp handle_stream_thinking_delta(_stream_state_key, _intent, _opts, _delta), do: :ok

  defp emit_remaining_final_delta(
         stream_state_key,
         %Effect.Intent{} = intent,
         %Effect.LLMDecision{type: :final, content: content},
         opts
       )
       when is_binary(content) do
    state = Process.get(stream_state_key, %{raw: "", content: "", seq: 0})
    emit_new_content(intent, opts, state, content)
  end

  defp emit_remaining_final_delta(_stream_state_key, _intent, _decision, _opts), do: :ok

  defp emit_new_content(%Effect.Intent{} = intent, opts, state, content) do
    cond do
      content == state.content ->
        state

      String.starts_with?(content, state.content) ->
        delta = String.replace_prefix(content, state.content, "")
        emit_delta(intent, opts, :content, delta, state.seq)
        %{state | content: content, seq: state.seq + 1}

      true ->
        %{state | content: content}
    end
  end

  defp emit_delta(_intent, _opts, _chunk_type, "", _seq), do: :ok

  defp emit_delta(%Effect.Intent{} = intent, opts, chunk_type, delta, seq) do
    payload = intent.payload

    Event.new!(
      event: :llm_delta,
      seq: seq,
      agent_id: Schema.get_key(payload, :agent_id),
      request_id: Schema.get_key(payload, :request_id),
      loop_index: Schema.get_key(payload, :loop_index),
      effect_id: intent.id,
      effect_kind: :llm,
      data: %{chunk_type: chunk_type, delta: delta}
    )
    |> EventDispatcher.emit(opts)
  end

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
    if hex?(hex) do
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
      codepoint when codepoint in 0xD800..0xDFFF ->
        acc_to_binary(acc)

      codepoint ->
        decode_json_string_prefix(rest, [<<codepoint::utf8>> | acc])
    end
  rescue
    ArgumentError -> acc_to_binary(acc)
  end

  defp hex?(hex), do: String.match?(hex, ~r/\A[0-9a-fA-F]{4}\z/)
end
