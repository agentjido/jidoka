defmodule Jidoka.Agent.Definition.LifecycleConfig do
  @moduledoc false

  @spec resolve_hooks!([struct()], module()) :: map()
  def resolve_hooks!(hook_entities, owner_module) when is_list(hook_entities) do
    hook_entities
    |> hooks_stage_map()
    |> normalize_hooks!(owner_module)
  end

  @spec resolve_guardrails!([struct()], module()) :: map()
  def resolve_guardrails!(guardrail_entities, owner_module) when is_list(guardrail_entities) do
    guardrail_entities
    |> guardrails_stage_map(owner_module)
    |> normalize_guardrails!(owner_module)
  end

  defp normalize_hooks!(hooks, owner_module) do
    with :ok <- ensure_unique_stage_refs!(owner_module, hooks, "hook", [:lifecycle]),
         {:ok, normalized} <- Jidoka.Hooks.normalize_dsl_hooks(hooks) do
      normalized
    else
      {:error, message} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: message,
                path: [:lifecycle],
                hint: "Declare hooks as `before_turn`, `after_turn`, or `on_interrupt` inside `lifecycle`.",
                module: owner_module
              )
    end
  end

  defp normalize_guardrails!(guardrails, owner_module) do
    with :ok <- ensure_unique_stage_refs!(owner_module, guardrails, "control", [:controls]),
         {:ok, normalized} <- Jidoka.Guardrails.normalize_dsl_guardrails(guardrails) do
      normalized
    else
      {:error, message} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: message,
                path: [:controls],
                hint: "Declare controls as `input`, `operation`, or `result` inside `controls`.",
                module: owner_module
              )
    end
  end

  defp ensure_unique_stage_refs!(owner_module, stage_map, label, path) when is_map(stage_map) do
    stage_map
    |> Enum.find_value(fn {stage, refs} ->
      duplicate =
        refs
        |> Enum.frequencies()
        |> Enum.find(fn {_ref, count} -> count > 1 end)

      case duplicate do
        nil -> nil
        {ref, _count} -> {stage, ref}
      end
    end)
    |> case do
      nil ->
        :ok

      {stage, ref} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: "#{label} #{inspect(ref)} is defined more than once for #{stage}",
                path: path ++ [stage],
                value: ref,
                hint: "Remove the duplicate #{label} declaration from the #{stage} stage.",
                module: owner_module
              )
    end
  end

  defp hooks_stage_map(hook_entities) do
    Enum.reduce(hook_entities, Jidoka.Hooks.default_stage_map(), fn
      %Jidoka.Agent.Dsl.BeforeTurnHook{hook: hook}, acc ->
        Map.update!(acc, :before_turn, &(&1 ++ [hook]))

      %Jidoka.Agent.Dsl.AfterTurnHook{hook: hook}, acc ->
        Map.update!(acc, :after_turn, &(&1 ++ [hook]))

      %Jidoka.Agent.Dsl.InterruptHook{hook: hook}, acc ->
        Map.update!(acc, :on_interrupt, &(&1 ++ [hook]))
    end)
  end

  defp guardrails_stage_map(guardrail_entities, owner_module) do
    Enum.reduce(guardrail_entities, Jidoka.Guardrails.default_stage_map(), fn
      %Jidoka.Agent.Dsl.InputGuardrail{guardrail: guardrail}, acc ->
        Map.update!(acc, :input, &(&1 ++ [guardrail]))

      %Jidoka.Agent.Dsl.OutputGuardrail{guardrail: guardrail}, acc ->
        Map.update!(acc, :output, &(&1 ++ [guardrail]))

      %Jidoka.Agent.Dsl.ToolGuardrail{guardrail: guardrail, match: match}, acc ->
        Map.update!(acc, :tool, &(&1 ++ [operation_control!(owner_module, guardrail, match)]))
    end)
  end

  defp operation_control!(_owner_module, guardrail, nil), do: guardrail

  defp operation_control!(owner_module, guardrail, match) do
    %Jidoka.Control.Operation{ref: guardrail, match: normalize_operation_match!(owner_module, match)}
  end

  defp normalize_operation_match!(owner_module, match) when is_list(match) do
    match
    |> Map.new()
    |> then(&normalize_operation_match!(owner_module, &1))
  end

  defp normalize_operation_match!(owner_module, %{} = match) do
    allowed_keys = [:kind, "kind", :name, "name"]

    case Enum.reject(Map.keys(match), &(&1 in allowed_keys)) do
      [] ->
        %{}
        |> maybe_put_kind(owner_module, Map.get(match, :kind, Map.get(match, "kind")))
        |> maybe_put_name(Map.get(match, :name, Map.get(match, "name")))

      unknown ->
        raise_operation_match_error!(owner_module, "unknown operation control match keys: #{inspect(unknown)}", match)
    end
  end

  defp normalize_operation_match!(owner_module, other) do
    raise_operation_match_error!(
      owner_module,
      "operation control `when` must be a keyword list or map, got: #{inspect(other)}",
      other
    )
  end

  defp maybe_put_kind(match, _owner_module, nil), do: match

  defp maybe_put_kind(match, owner_module, kind) do
    Map.put(match, :kind, normalize_match_kind!(owner_module, kind))
  end

  defp maybe_put_name(match, nil), do: match
  defp maybe_put_name(match, name), do: Map.put(match, :name, name |> to_string() |> String.trim())

  defp normalize_match_kind!(_owner_module, value) when value in [:action, :tool, :workflow, :subagent, :handoff],
    do: value

  defp normalize_match_kind!(owner_module, value) when is_binary(value) do
    case String.trim(value) do
      "action" -> :action
      "tool" -> :tool
      "workflow" -> :workflow
      "subagent" -> :subagent
      "handoff" -> :handoff
      _other -> raise_operation_match_error!(owner_module, "operation control kind has unsupported value", value)
    end
  end

  defp normalize_match_kind!(owner_module, value) do
    raise_operation_match_error!(
      owner_module,
      "operation control kind must be one of :action, :tool, :workflow, :subagent, or :handoff",
      value
    )
  end

  defp raise_operation_match_error!(owner_module, message, value) do
    raise Jidoka.Agent.Dsl.Error.exception(
            message: message,
            path: [:controls, :operation, :when],
            value: value,
            hint: "Use `operation MyControl, when: [kind: :action, name: :tool_name]`.",
            module: owner_module
          )
  end
end
