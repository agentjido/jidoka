defmodule Jidoka.Runtime.ReqLLM do
  @moduledoc """
  ReqLLM runtime support for Jidoka's LLM effect boundary.

  The MVP runtime uses a constrained JSON protocol instead of native provider
  tool-calling. That keeps Jidoka's Runic spine provider-neutral while still
  letting a real model choose between final answers and operation calls.
  """

  alias Jidoka.Agent.Spec.Generation
  alias Jidoka.Config
  alias Jidoka.Effect
  alias Jidoka.Runtime.ReqLLM.Decision
  alias Jidoka.Schema

  @type option ::
          {:model, ReqLLM.model_input()}
          | {:temperature, number()}
          | {:max_tokens, pos_integer()}
          | {:timeout, timeout()}
          | {:receive_timeout, timeout()}
          | {:provider_options, map()}
          | {:cache, term()}

  @doc """
  Returns an LLM function suitable for `Jidoka.run_turn/3`.

      llm = Jidoka.Runtime.ReqLLM.llm(model: "openai:gpt-4o-mini", temperature: 0.0)
      Jidoka.run_turn(agent, "Use the available tool.", llm: llm, operations: ops)
  """
  @spec llm([option()]) :: Jidoka.Runtime.Capabilities.llm_capability()
  def llm(opts \\ []) when is_list(opts) do
    fn %Effect.Intent{} = intent, %Effect.Journal{} = journal ->
      generate(intent, journal, opts)
    end
  end

  @doc false
  @spec generate(Effect.Intent.t(), Effect.Journal.t(), [option()]) ::
          {:ok, map()} | {:error, term()}
  def generate(%Effect.Intent{kind: :llm, payload: payload}, _journal, opts) do
    llm_opts =
      payload
      |> generation_opts()
      |> Keyword.merge(Keyword.drop(opts, [:model]))

    with {:ok, model} <- fetch_model(payload, opts),
         {:ok, messages} <- build_messages(payload),
         {:ok, response} <- ReqLLM.Generation.generate_text(model, messages, llm_opts) do
      response
      |> ReqLLM.Response.text()
      |> Decision.parse_text()
    end
  end

  def generate(%Effect.Intent{kind: kind}, _journal, _opts),
    do: {:error, {:unsupported_effect_kind, kind}}

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
    with {:ok, prompt} when is_map(prompt) <- Schema.fetch_key(payload, :prompt) do
      build_prompt_messages(prompt)
    else
      {:ok, prompt} -> {:error, {:invalid_prompt_payload, prompt}}
      :error -> {:error, {:missing_prompt_payload, payload}}
    end
  end

  defp build_prompt_messages(prompt) do
    {:ok,
     [
       %{role: :system, content: runtime_system_prompt()},
       %{role: :user, content: Jason.encode!(prompt)}
     ]}
  rescue
    exception -> {:error, {:invalid_prompt_payload, exception}}
  end

  defp runtime_system_prompt do
    """
    You are the model side of a Jidoka agent turn.

    Return exactly one JSON object and no markdown.

    To answer the user directly:
    {"type":"final","content":"your answer"}

    To call an available operation:
    {"type":"operation","name":"operation_name","arguments":{}}

    Use only operations listed in the prompt payload. If a tool observation is
    present in the message history, use it to produce the final answer.
    """
  end
end
