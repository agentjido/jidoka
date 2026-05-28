defmodule Jidoka.PromptPreflight do
  @moduledoc false

  alias Jido.AI.Reasoning.ReAct.{Config, State}
  alias Jidoka.ImportedAgent

  @type t :: %{
          kind: :prompt_preflight,
          agent_id: String.t(),
          agent_module: module() | nil,
          runtime_module: module(),
          request_id: String.t(),
          input_message: String.t(),
          context: map(),
          sections: [map()],
          system_prompt: String.t(),
          messages: [map()],
          provider_messages: [map()],
          message_count: non_neg_integer()
        }

  @spec run(module() | ImportedAgent.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def run(agent, message, opts \\ [])

  def run(module, message, opts) when is_atom(module) and is_binary(message) and is_list(opts) do
    with {:ok, definition} <- module_definition(module) do
      run_definition(definition, message, opts)
    end
  end

  def run(%ImportedAgent{} = agent, message, opts) when is_binary(message) and is_list(opts) do
    agent
    |> ImportedAgent.definition()
    |> Map.put(:request_transformer_system_prompt, agent.spec.instructions)
    |> Map.put(:character_spec, agent.character_spec)
    |> Map.put(:skills, %{refs: agent.skill_refs, load_paths: agent.spec.skill_paths})
    |> Map.put(:ash_tool_config, nil)
    |> run_definition(message, opts)
  end

  def run(_agent, message, _opts) when not is_binary(message) do
    {:error,
     Jidoka.Error.validation_error("Prompt preflight message must be a string.",
       field: :message,
       value: message,
       details: %{operation: :prompt_preflight, reason: :expected_string}
     )}
  end

  def run(agent, _message, _opts) do
    {:error,
     Jidoka.Error.config_error("Prompt preflight target is not a Jidoka agent.",
       field: :agent,
       value: agent,
       details: %{operation: :prompt_preflight, reason: :not_jidoka_agent}
     )}
  end

  defp module_definition(module) do
    _ = Code.ensure_loaded(module)

    cond do
      function_exported?(module, :__jidoka__, 0) ->
        {:ok, module.__jidoka__()}

      function_exported?(module, :__jidoka_definition__, 0) ->
        {:ok, module.__jidoka_definition__()}

      true ->
        {:error,
         Jidoka.Error.config_error("Module is not a Jidoka agent.",
           field: :agent,
           value: module,
           details: %{operation: :prompt_preflight, reason: :not_jidoka_agent}
         )}
    end
  end

  defp run_definition(definition, message, opts) do
    request_id = Keyword.get(opts, :request_id, "prompt-preflight-#{System.unique_integer([:positive])}")

    with {:ok, prepared_opts} <- Jidoka.Agent.prepare_chat_opts(opts, preflight_config(definition)),
         {:ok, request} <- build_request(message, prepared_opts),
         runtime_context <- preflight_context(definition, prepared_opts),
         {:ok, preflight} <-
           Jidoka.Agent.RequestTransformer.prompt_preflight(
             system_prompt_spec(definition),
             Map.get(definition, :character_spec),
             Map.get(definition, :skills),
             request,
             preflight_state(message, request_id),
             preflight_react_config(definition),
             runtime_context
           ) do
      {:ok,
       preflight
       |> Map.merge(%{
         kind: :prompt_preflight,
         agent_id: definition.id,
         agent_module: Map.get(definition, :module),
         runtime_module: definition.runtime_module,
         request_id: request_id,
         input_message: message,
         context: Jidoka.Context.strip_internal(runtime_context)
       })}
    end
  end

  defp preflight_config(definition) do
    %{
      context: Map.get(definition, :context, %{}),
      context_schema: Map.get(definition, :context_schema),
      ash: Map.get(definition, :ash_tool_config)
    }
  end

  defp system_prompt_spec(definition) do
    Map.get(definition, :request_transformer_system_prompt, Map.get(definition, :instructions))
  end

  defp build_request(message, opts) do
    {:ok,
     %{
       query: message,
       prompt: message,
       messages: [%{role: :user, content: message}],
       tools: %{},
       llm_opts: Keyword.get(opts, :llm_opts, [])
     }}
  end

  defp preflight_context(definition, opts) do
    definition
    |> maybe_attach_default_output(Keyword.fetch!(opts, :tool_context))
  end

  defp maybe_attach_default_output(definition, context) do
    output = Map.get(definition, :result, Map.get(definition, :output))
    key = Jidoka.Output.context_key()

    cond do
      is_nil(output) ->
        context

      raw_output_context?(Map.get(context, key) || Map.get(context, Atom.to_string(key))) ->
        context

      is_nil(Jidoka.Output.runtime_output(context)) ->
        Map.put(context, key, %{output: output})

      true ->
        context
    end
  end

  defp raw_output_context?(%{mode: :raw}), do: true
  defp raw_output_context?(%{mode: "raw"}), do: true
  defp raw_output_context?(_context), do: false

  defp preflight_state(message, request_id) do
    State.new(message, nil, request_id: request_id, run_id: request_id)
  end

  defp preflight_react_config(definition) do
    Config.new(
      model: Map.get(definition, :model),
      system_prompt: Map.get(definition, :runtime_system_prompt),
      request_transformer: Map.get(definition, :effective_request_transformer),
      streaming: false
    )
  end
end
