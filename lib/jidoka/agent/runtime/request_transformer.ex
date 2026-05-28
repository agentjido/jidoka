defmodule Jidoka.Agent.RequestTransformer do
  @moduledoc false

  alias Jido.AI.Reasoning.ReAct.{Config, State}

  @spec transform_request(
          Jidoka.Agent.SystemPrompt.spec() | nil,
          Jidoka.Character.spec(),
          Jidoka.Skill.config() | nil,
          map(),
          State.t(),
          Config.t(),
          map()
        ) :: {:ok, %{messages: [map()]}} | {:error, term()}
  def transform_request(
        system_prompt_spec,
        character_spec,
        skills_config,
        request,
        %State{} = state,
        %Config{} = config,
        runtime_context
      )
      when is_map(request) and is_map(runtime_context) do
    with {:ok, preflight} <-
           prompt_preflight(system_prompt_spec, character_spec, skills_config, request, state, config, runtime_context) do
      Jidoka.Debug.record_prompt_preview(
        runtime_context,
        preflight.system_prompt,
        Map.put(request, :messages, preflight.provider_messages)
      )

      Jidoka.Debug.record_runtime_meta(runtime_context, %{prompt_sections: preflight.sections})
      {:ok, %{messages: preflight.messages}}
    end
  end

  @spec transform_request(
          Jidoka.Agent.SystemPrompt.spec() | nil,
          Jidoka.Skill.config() | nil,
          map(),
          State.t(),
          Config.t(),
          map()
        ) :: {:ok, %{messages: [map()]}} | {:error, term()}
  def transform_request(system_prompt_spec, skills_config, request, state, config, runtime_context) do
    transform_request(system_prompt_spec, nil, skills_config, request, state, config, runtime_context)
  end

  @doc false
  @spec prompt_preflight(
          Jidoka.Agent.SystemPrompt.spec() | nil,
          Jidoka.Character.spec(),
          Jidoka.Skill.config() | nil,
          map(),
          State.t(),
          Config.t(),
          map()
        ) ::
          {:ok,
           %{
             sections: [map()],
             system_prompt: String.t(),
             provider_messages: [map()],
             messages: [map()],
             message_count: non_neg_integer()
           }}
          | {:error, term()}
  def prompt_preflight(
        system_prompt_spec,
        character_spec,
        skills_config,
        request,
        %State{} = state,
        %Config{} = config,
        runtime_context
      )
      when is_map(request) and is_map(runtime_context) do
    input = %{
      request: request,
      state: state,
      config: config,
      context: runtime_context
    }

    with {:ok, prompt} <- resolve_base_prompt(system_prompt_spec, input),
         {:ok, character_prompt} <- resolve_character_prompt(character_spec, input, runtime_context) do
      messages =
        request
        |> Map.get(:messages, [])
        |> Jidoka.Compaction.apply_to_messages(runtime_context)

      sections =
        prompt_sections(character_prompt, prompt, system_prompt_spec, character_spec, skills_config, runtime_context)

      system_prompt = join_prompt_sections(sections)

      {:ok,
       %{
         sections: sections,
         system_prompt: system_prompt,
         provider_messages: messages,
         messages: apply_prompt(messages, system_prompt),
         message_count: length(messages)
       }}
    end
  end

  defp resolve_base_prompt(nil, %{request: request}),
    do: {:ok, Jidoka.Agent.SystemPrompt.extract_system_prompt(request.messages)}

  defp resolve_base_prompt(spec, input), do: Jidoka.Agent.SystemPrompt.resolve(spec, input)

  defp resolve_character_prompt(character_spec, input, runtime_context) do
    runtime_context
    |> Jidoka.Character.runtime_override()
    |> case do
      nil -> character_spec
      override -> override
    end
    |> Jidoka.Character.resolve(input)
  end

  defp prompt_sections(character_prompt, prompt, system_prompt_spec, character_spec, skills_config, runtime_context) do
    [
      prompt_section(:character, character_prompt, character_provenance(character_spec, runtime_context)),
      prompt_section(:instructions, prompt, instructions_provenance(system_prompt_spec)),
      prompt_section(:compaction, Jidoka.Compaction.prompt_text(runtime_context), %{
        feature: :compaction,
        source: :runtime_context,
        context_key: Jidoka.Compaction.context_key()
      }),
      prompt_section(:skills, skills_prompt(skills_config, runtime_context), %{
        feature: :skills,
        source: :runtime_context,
        context_key: Jidoka.Skill.context_key(),
        configured?: Jidoka.Skill.enabled?(skills_config)
      }),
      prompt_section(:memory, Jidoka.Memory.prompt_text(runtime_context), %{
        feature: :memory,
        source: :runtime_context,
        context_key: Jidoka.Memory.context_key()
      }),
      prompt_section(:result, Jidoka.Output.instructions(runtime_context), %{
        feature: :result,
        source: :runtime_context,
        context_key: Jidoka.Output.context_key()
      })
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {section, order} -> Map.put(section, :order, order) end)
  end

  defp skills_prompt(nil, runtime_context), do: Jidoka.Skill.prompt_text(runtime_context)
  defp skills_prompt(_config, runtime_context), do: Jidoka.Skill.prompt_text(runtime_context)

  defp prompt_section(_name, nil, _provenance), do: nil

  defp prompt_section(name, content, provenance) do
    case normalize_prompt(content) do
      nil ->
        nil

      prompt ->
        %{
          name: name,
          source: provenance.source,
          provenance: provenance,
          content: prompt
        }
    end
  end

  defp join_prompt_sections(sections) do
    sections
    |> Enum.map(& &1.content)
    |> Enum.join("\n\n")
  end

  defp instructions_provenance(nil) do
    %{feature: :instructions, source: :request_system_prompt, configured?: false}
  end

  defp instructions_provenance(spec) do
    %{
      feature: :instructions,
      source: :agent_instructions,
      configured?: true,
      resolver: prompt_spec_summary(spec)
    }
  end

  defp character_provenance(character_spec, runtime_context) do
    override = Jidoka.Character.runtime_override(runtime_context)
    effective = override || character_spec

    %{
      feature: :character,
      source: if(is_nil(override), do: :agent_character, else: :request_character),
      configured?: not is_nil(effective),
      runtime_override?: not is_nil(override),
      resolver: prompt_spec_summary(effective),
      context_key: Jidoka.Character.context_key()
    }
  end

  defp prompt_spec_summary(nil), do: nil
  defp prompt_spec_summary(prompt) when is_binary(prompt), do: %{type: :static}
  defp prompt_spec_summary(module) when is_atom(module), do: %{type: :module, module: inspect(module)}

  defp prompt_spec_summary({module, function, args}) when is_atom(module) and is_atom(function) and is_list(args) do
    %{type: :mfa, module: inspect(module), function: function, arity: length(args) + 1}
  end

  defp prompt_spec_summary({:character, _character}), do: %{type: :character}
  defp prompt_spec_summary(:none), do: %{type: :none}
  defp prompt_spec_summary(other), do: %{type: :term, value: inspect(other)}

  defp apply_prompt(messages, ""), do: messages

  defp apply_prompt(messages, prompt),
    do: Jidoka.Agent.SystemPrompt.put_system_prompt(messages, prompt)

  defp normalize_prompt(nil), do: nil
  defp normalize_prompt(prompt) when is_binary(prompt) and prompt == "", do: nil
  defp normalize_prompt(prompt) when is_binary(prompt), do: prompt
end
