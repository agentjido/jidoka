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
  alias Jidoka.Adapter.ReqLLM.NormalizedStream
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
      generate_text_response(model, messages, llm_opts, intent, opts)
    end
  end

  defp generate_text_response(model, messages, llm_opts, %Effect.Intent{} = intent, opts) do
    state = NormalizedStream.new()

    case ReqLLM.Generation.generate_text(model, messages, llm_opts) do
      {:ok, response} -> finish_response(state, response, model, intent, opts)
      {:error, reason} -> fail_response(state, reason, intent, opts)
    end
  end

  defp generate_streaming_response(model, messages, llm_opts, %Effect.Intent{} = intent, opts) do
    stream_state_key = {__MODULE__, :stream_state, make_ref()}
    Process.put(stream_state_key, NormalizedStream.new())

    result =
      case ReqLLM.Generation.stream_text(model, messages, llm_opts) do
        {:ok, stream_response} ->
          case ReqLLM.StreamResponse.process_stream(stream_response,
                 on_chunk: &handle_stream_chunk(stream_state_key, intent, opts, &1)
               ) do
            {:ok, response} ->
              state = Process.get(stream_state_key, NormalizedStream.new())
              finish_response(state, response, model, intent, opts)

            {:error, reason} ->
              state = Process.get(stream_state_key, NormalizedStream.new())
              fail_response(state, reason, intent, opts)
          end

        {:error, reason} ->
          fail_response(NormalizedStream.new(), reason, intent, opts)
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

  defp stream_enabled?(opts) do
    case Keyword.fetch(opts, :stream) do
      {:ok, enabled?} -> enabled? == true
      :error -> Keyword.has_key?(opts, :stream_to) or Keyword.has_key?(opts, :on_event)
    end
  end

  defp handle_stream_chunk(stream_state_key, %Effect.Intent{} = intent, opts, chunk) do
    state = Process.get(stream_state_key, NormalizedStream.new())
    {state, records} = NormalizedStream.push(state, chunk)
    Process.put(stream_state_key, state)
    emit_records(records, intent, opts)
  end

  defp finish_response(state, response, model, %Effect.Intent{} = intent, opts) do
    text = response_text(state, response)

    case ResponseAdapter.decision(response, model, text, prompt: Schema.get_key(intent.payload, :prompt)) do
      {:ok, decision} ->
        {_state, records} = NormalizedStream.complete(state, response, decision)
        emit_records(records, intent, opts)
        {:ok, decision}

      {:error, reason} ->
        fail_response(state, reason, intent, opts)
    end
  end

  defp fail_response(state, reason, %Effect.Intent{} = intent, opts) do
    {_state, records} = NormalizedStream.fail(state, reason)
    emit_records(records, intent, opts)
    {:error, reason}
  end

  defp response_text(%NormalizedStream{} = state, response) do
    text = ReqLLM.Response.text(response)
    raw = NormalizedStream.raw_text(state)

    cond do
      is_binary(text) and String.trim(text) != "" -> text
      is_binary(raw) and String.trim(raw) != "" -> raw
      true -> text
    end
  end

  defp emit_records(records, %Effect.Intent{} = intent, opts) do
    Enum.each(records, &emit_record(&1, intent, opts))
  end

  defp emit_record(record, %Effect.Intent{} = intent, opts) do
    payload = intent.payload

    Event.new!(
      event: :llm_delta,
      agent_id: Schema.get_key(payload, :agent_id),
      request_id: Schema.get_key(payload, :request_id),
      loop_index: Schema.get_key(payload, :loop_index),
      effect_id: intent.id,
      effect_kind: :llm,
      data: event_data(record)
    )
    |> EventDispatcher.emit(opts)
  end

  defp event_data(%{type: :text_delta} = record),
    do: record |> Map.put(:chunk_type, :content)

  defp event_data(%{type: :reasoning_delta} = record),
    do: record |> Map.put(:chunk_type, :thinking)

  defp event_data(record), do: record
end
