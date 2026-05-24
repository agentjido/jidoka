defmodule Jidoka.Agent.Definition.Basics do
  @moduledoc false

  @spec resolve_agent_id!(module(), term()) :: String.t()
  def resolve_agent_id!(owner_module, id) do
    normalized_id =
      cond do
        is_atom(id) and not is_nil(id) ->
          Atom.to_string(id)

        is_binary(id) ->
          String.trim(id)

        true ->
          raise Jidoka.Agent.Dsl.Error.exception(
                  message: "`agent` id is required.",
                  path: [:agent],
                  value: id,
                  hint: "Declare `agent :my_agent do ... end` using lower snake case.",
                  module: owner_module
                )
      end

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, normalized_id) do
      normalized_id
    else
      raise Jidoka.Agent.Dsl.Error.exception(
              message: "`agent` id must be lower snake case.",
              path: [:agent],
              value: id,
              hint: "Use a value like `support_agent` with lowercase letters, numbers, and underscores.",
              module: owner_module
            )
    end
  end

  @spec require_instructions!(module(), term()) :: :ok
  def require_instructions!(owner_module, nil) do
    raise Jidoka.Agent.Dsl.Error.exception(
            message: "`agent.instructions` is required.",
            path: [:agent, :instructions],
            value: nil,
            hint: "Declare `agent :my_agent do instructions \"...\" end` or provide a resolver module/MFA.",
            module: owner_module
          )
  end

  def require_instructions!(_owner_module, _instructions), do: :ok

  @spec resolve_model!(module(), term()) :: term()
  def resolve_model!(owner_module, model) do
    Jidoka.Model.model(model)
  rescue
    error in [ArgumentError] ->
      raise Jidoka.Agent.Dsl.Error.exception(
              message: Exception.message(error),
              path: [:agent, :model],
              value: model,
              hint: "Use a configured Jidoka model alias such as `:fast` or a Jido.AI-compatible model spec.",
              module: owner_module
            )
  end

  @spec resolve_instructions!(module(), term()) :: {:static, String.t()} | {:dynamic, term()}
  def resolve_instructions!(owner_module, instructions) do
    case Jidoka.Agent.SystemPrompt.normalize(owner_module, instructions, label: "instructions") do
      {:ok, normalized} ->
        normalized

      {:error, message} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: message,
                path: [:agent, :instructions],
                value: instructions,
                hint: "Use a non-empty string, a module implementing `resolve_system_prompt/1`, or an MFA tuple.",
                module: owner_module
              )
    end
  end

  @spec resolve_character!(module(), term()) :: nil | Jidoka.Character.spec()
  def resolve_character!(_owner_module, nil), do: nil

  def resolve_character!(owner_module, character) do
    case Jidoka.Character.normalize(owner_module, character, label: "character") do
      {:ok, normalized} ->
        normalized

      {:error, message} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: message,
                path: [:agent, :character],
                value: character,
                hint: "Use an inline `Jido.Character` map or a `use Jido.Character` module.",
                module: owner_module
              )
    end
  end
end
