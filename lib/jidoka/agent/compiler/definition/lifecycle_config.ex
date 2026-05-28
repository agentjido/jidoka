defmodule Jidoka.Agent.Definition.LifecycleConfig do
  @moduledoc false

  @spec resolve_guardrails!([struct()], module()) :: map()
  def resolve_guardrails!(guardrail_entities, owner_module) when is_list(guardrail_entities) do
    guardrail_entities
    |> guardrails_stage_map(owner_module)
    |> normalize_guardrails!(owner_module)
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

  defp guardrails_stage_map(guardrail_entities, owner_module) do
    Enum.reduce(guardrail_entities, Jidoka.Guardrails.default_stage_map(), fn
      %Jidoka.Agent.Dsl.InputControl{control: control}, acc ->
        Map.update!(acc, :input, &(&1 ++ [control]))

      %Jidoka.Agent.Dsl.ResultControl{control: control}, acc ->
        Map.update!(acc, :output, &(&1 ++ [control]))

      %Jidoka.Agent.Dsl.OperationControl{control: control, match: match}, acc ->
        Map.update!(acc, :tool, &(&1 ++ [operation_control!(owner_module, control, match)]))
    end)
  end

  defp operation_control!(_owner_module, control, nil), do: control

  defp operation_control!(owner_module, control, match) do
    %Jidoka.Control.Operation{ref: control, match: normalize_operation_match!(owner_module, match)}
  end

  defp normalize_operation_match!(owner_module, match) when is_list(match) do
    match
    |> Map.new()
    |> then(&normalize_operation_match!(owner_module, &1))
  end

  defp normalize_operation_match!(owner_module, %{} = match) do
    allowed_keys = [
      :kind,
      "kind",
      :name,
      "name",
      :credential,
      "credential",
      :credential_provider,
      "credential_provider",
      :credential_account,
      "credential_account",
      :credential_actor,
      "credential_actor",
      :credential_tenant,
      "credential_tenant",
      :credential_scope,
      "credential_scope",
      :credential_scopes,
      "credential_scopes",
      :credential_risk,
      "credential_risk",
      :confirmation_required,
      "confirmation_required"
    ]

    case Enum.reject(Map.keys(match), &(&1 in allowed_keys)) do
      [] ->
        %{}
        |> maybe_put_kind(owner_module, Map.get(match, :kind, Map.get(match, "kind")))
        |> maybe_put_name(Map.get(match, :name, Map.get(match, "name")))
        |> maybe_put_credential_match(owner_module, match)

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

  defp maybe_put_credential_match(acc, owner_module, match) do
    credential_match =
      match
      |> credential_match_attrs()
      |> then(&normalize_credential_match!(owner_module, &1))

    case credential_match do
      empty when empty == %{} -> acc
      credential_match -> Map.put(acc, :credential, credential_match)
    end
  end

  defp credential_match_attrs(match) do
    base =
      match
      |> Map.get(:credential, Map.get(match, "credential", %{}))
      |> case do
        nil -> %{}
        attrs when is_list(attrs) -> Map.new(attrs)
        attrs when is_map(attrs) -> attrs
        other -> %{invalid_credential_match: other}
      end

    base
    |> maybe_put_match_attr(:provider, match, :credential_provider)
    |> maybe_put_match_attr(:account, match, :credential_account)
    |> maybe_put_match_attr(:actor, match, :credential_actor)
    |> maybe_put_match_attr(:tenant, match, :credential_tenant)
    |> maybe_put_match_attr(:scope, match, :credential_scope)
    |> maybe_put_match_attr(:scopes, match, :credential_scopes)
    |> maybe_put_match_attr(:risk, match, :credential_risk)
    |> maybe_put_match_attr(:confirmation_required, match, :confirmation_required)
  end

  defp maybe_put_match_attr(acc, key, source, source_key) do
    case Map.get(source, source_key, Map.get(source, Atom.to_string(source_key))) do
      nil -> acc
      value -> Map.put(acc, key, value)
    end
  end

  defp normalize_credential_match!(owner_module, %{invalid_credential_match: value}) do
    raise_operation_match_error!(
      owner_module,
      "operation control credential match must be a keyword list or map",
      value
    )
  end

  defp normalize_credential_match!(owner_module, %{} = match) do
    allowed_keys = [
      :provider,
      "provider",
      :account,
      "account",
      :actor,
      "actor",
      :tenant,
      "tenant",
      :scope,
      "scope",
      :scopes,
      "scopes",
      :risk,
      "risk",
      :confirmation_required,
      "confirmation_required"
    ]

    case Enum.reject(Map.keys(match), &(&1 in allowed_keys)) do
      [] ->
        %{}
        |> maybe_put_string_match(:provider, match)
        |> maybe_put_string_match(:account, match)
        |> maybe_put_string_match(:actor, match)
        |> maybe_put_string_match(:tenant, match)
        |> maybe_put_string_match(:scope, match)
        |> maybe_put_scopes_match(owner_module, match)
        |> maybe_put_risk_match(owner_module, match)
        |> maybe_put_confirmation_match(owner_module, match)

      unknown ->
        raise_operation_match_error!(
          owner_module,
          "unknown credential match keys: #{inspect(unknown)}",
          match
        )
    end
  end

  defp normalize_credential_match!(owner_module, other) do
    raise_operation_match_error!(
      owner_module,
      "operation control credential match must be a keyword list or map",
      other
    )
  end

  defp maybe_put_string_match(acc, key, match) do
    case Map.get(match, key, Map.get(match, Atom.to_string(key))) do
      nil -> acc
      value -> Map.put(acc, key, value |> to_string() |> String.trim())
    end
  end

  defp maybe_put_scopes_match(acc, owner_module, match) do
    case Map.get(match, :scopes, Map.get(match, "scopes")) do
      nil ->
        acc

      scopes when is_list(scopes) ->
        Map.put(acc, :scopes, Enum.map(scopes, &(to_string(&1) |> String.trim())))

      other ->
        raise_operation_match_error!(owner_module, "credential scopes match must be a list", other)
    end
  end

  defp maybe_put_risk_match(acc, owner_module, match) do
    case Map.get(match, :risk, Map.get(match, "risk")) do
      nil -> acc
      risk -> Map.put(acc, :risk, normalize_credential_risk!(owner_module, risk))
    end
  end

  defp normalize_credential_risk!(_owner_module, risk) when risk in [:unknown, :low, :medium, :high, :critical],
    do: risk

  defp normalize_credential_risk!(owner_module, risk) when is_binary(risk) do
    risk = risk |> String.trim() |> String.downcase()

    Enum.find_value(Jidoka.Credential.risks(), fn allowed ->
      if Atom.to_string(allowed) == risk, do: allowed
    end) ||
      raise_operation_match_error!(owner_module, "credential risk match has unsupported value", risk)
  end

  defp normalize_credential_risk!(owner_module, risk) do
    raise_operation_match_error!(owner_module, "credential risk match has unsupported value", risk)
  end

  defp maybe_put_confirmation_match(acc, owner_module, match) do
    case Map.get(match, :confirmation_required, Map.get(match, "confirmation_required")) do
      nil -> acc
      value when is_boolean(value) -> Map.put(acc, :confirmation_required, value)
      other -> raise_operation_match_error!(owner_module, "confirmation_required match must be a boolean", other)
    end
  end

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
