defmodule Jidoka.Agent.Verifiers.VerifyAgent do
  @moduledoc false

  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

    case Spark.Dsl.Verifier.get_entities(dsl_state, [:jidoka]) do
      [%Jidoka.Agent.Dsl.Agent{} = agent] ->
        verify_agent(module, agent)

      [] ->
        {:error,
         dsl_error(
           "Declare `agent :id do ... end` before using a Jidoka agent module.",
           module,
           [:agent]
         )}

      agents ->
        {:error,
         dsl_error(
           "Only one `agent :id do ... end` block is allowed, got #{length(agents)}.",
           module,
           [:agent]
         )}
    end
  end

  defp verify_agent(module, agent) do
    cond do
      not valid_id?(agent.id) ->
        {:error,
         dsl_error(
           "`agent` id must be lower snake case.",
           module,
           [:agent],
           agent,
           "Use a value like `support_agent` with lowercase letters, numbers, and underscores."
         )}

      not valid_instructions?(agent.instructions) ->
        {:error,
         dsl_error(
           "`agent.instructions` must be a non-empty string when provided.",
           module,
           [:agent, :instructions],
           agent
         )}

      not valid_model?(agent.model) ->
        {:error,
         dsl_error(
           "`agent.model` must be a valid ReqLLM/LLMDB model input when provided.",
           module,
           [:agent, :model],
           agent
         )}

      not valid_generation?(agent.generation) ->
        {:error,
         dsl_error(
           "`agent.generation` must be a map or keyword list when provided.",
           module,
           [:agent, :generation],
           agent
         )}

      not valid_result?(agent.result) ->
        {:error,
         dsl_error(
           "`agent.result` must be a Zoi schema or `Jidoka.Agent.Spec.Result` data when provided.",
           module,
           [:agent, :result],
           agent
         )}

      true ->
        :ok
    end
  end

  defp valid_id?(id) when is_atom(id) and not is_nil(id),
    do: id |> Atom.to_string() |> valid_id?()

  defp valid_id?(id) when is_binary(id), do: Regex.match?(~r/^[a-z][a-z0-9_]*$/, id)
  defp valid_id?(_id), do: false

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_instructions?(nil), do: true
  defp valid_instructions?(value), do: non_empty_string?(value)

  defp valid_model?(nil), do: true

  defp valid_model?(value),
    do: match?({:ok, _model}, Jidoka.Config.normalize_model_spec(value))

  defp valid_generation?(nil), do: true

  defp valid_generation?(value),
    do: match?({:ok, _generation}, Jidoka.Config.normalize_generation(value))

  defp valid_result?(nil), do: true

  defp valid_result?(value),
    do: match?({:ok, _result}, Jidoka.Agent.Spec.Result.from_input(value))

  defp dsl_error(message, module, path, entity \\ nil, hint \\ nil) do
    Spark.Error.DslError.exception(
      message: Enum.reject([message, hint_line(hint)], &is_nil/1) |> Enum.join("\n"),
      path: path,
      module: module,
      location: entity_location(entity)
    )
  end

  defp hint_line(nil), do: nil
  defp hint_line(hint), do: "Fix: #{hint}"

  defp entity_location(nil), do: nil
  defp entity_location(entity), do: Spark.Dsl.Entity.anno(entity)
end
