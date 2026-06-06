defmodule Jidoka.Workflow.Definition.Steps do
  @moduledoc false

  alias Jidoka.Workflow.Definition.{Error, Targets, Validation}
  alias Jidoka.Workflow.Dsl
  alias Jidoka.Workflow.RetryPolicy
  alias Jidoka.Workflow.Step

  @spec normalize!([struct()], module()) :: [Step.t()]
  def normalize!([], owner_module) do
    Error.raise!(
      owner_module,
      "A Jidoka workflow must declare at least one step.",
      [:steps],
      [],
      "Add a `steps do ... end` block with at least one `action`, `function`, or `agent` step."
    )
  end

  def normalize!(raw_steps, owner_module) do
    steps = Enum.map(raw_steps, &normalize_step!(&1, owner_module))
    Validation.ensure_unique_step_names!(owner_module, steps)
    steps
  end

  defp normalize_step!(%Dsl.ActionStep{} = step, owner_module) do
    Validation.validate_step_name!(owner_module, step.name, [:steps, :action])
    Targets.validate_action!(owner_module, step)
    Validation.validate_no_special_refs!(owner_module, [:steps, step.name, :input], step.input)
    common = common_attrs!(owner_module, step, [:steps, step.name])

    Step.new!(
      [
        kind: :action,
        name: step.name,
        target: step.module,
        input: step.input || %{}
      ] ++ common
    )
  end

  defp normalize_step!(%Dsl.FunctionStep{} = step, owner_module) do
    Validation.validate_step_name!(owner_module, step.name, [:steps, :function])
    Targets.validate_function!(owner_module, step)
    Validation.validate_no_special_refs!(owner_module, [:steps, step.name, :input], step.input)
    common = common_attrs!(owner_module, step, [:steps, step.name])

    Step.new!(
      [
        kind: :function,
        name: step.name,
        target: step.mfa,
        input: step.input || %{}
      ] ++ common
    )
  end

  defp normalize_step!(%Dsl.AgentStep{} = step, owner_module) do
    Validation.validate_step_name!(owner_module, step.name, [:steps, :agent])
    Targets.validate_agent!(owner_module, step)
    Validation.validate_no_special_refs!(owner_module, [:steps, step.name, :prompt], step.prompt)
    Validation.validate_no_special_refs!(owner_module, [:steps, step.name, :context], step.context)
    common = common_attrs!(owner_module, step, [:steps, step.name])

    Step.new!(
      [
        kind: :agent,
        name: step.name,
        target: step.agent,
        prompt: step.prompt,
        context: step.context || %{}
      ] ++ common
    )
  end

  defp normalize_step!(%Dsl.GateStep{} = step, owner_module) do
    Validation.validate_step_name!(owner_module, step.name, [:steps, :gate])

    Validation.validate_required!(
      owner_module,
      step.condition,
      [:steps, step.name, :condition],
      "Workflow gate steps require a condition."
    )

    Validation.validate_no_special_refs!(owner_module, [:steps, step.name, :condition], step.condition)

    Step.new!(
      kind: :gate,
      name: step.name,
      condition: step.condition,
      after: step.after || [],
      metadata: step.metadata || %{}
    )
  end

  defp normalize_step!(%Dsl.MapStep{} = step, owner_module) do
    Validation.validate_step_name!(owner_module, step.name, [:steps, :map])

    Validation.validate_required!(
      owner_module,
      step.over,
      [:steps, step.name, :over],
      "Workflow map steps require an `over` value."
    )

    Validation.validate_no_special_refs!(owner_module, [:steps, step.name, :over], step.over)
    Validation.validate_allowed_special_refs!(owner_module, [:steps, step.name, :input], step.params, [:item, :index])

    {target_kind, target} = normalize_map_target!(owner_module, step)

    max_concurrency =
      normalize_max_concurrency!(owner_module, step.max_concurrency, [:steps, step.name, :max_concurrency])

    common = common_attrs!(owner_module, step, [:steps, step.name])

    Step.new!(
      [
        kind: :map,
        name: step.name,
        target_kind: target_kind,
        target: target,
        over: step.over,
        input: step.params || %{},
        max_concurrency: max_concurrency
      ] ++ common
    )
  end

  defp normalize_step!(%Dsl.ReduceStep{} = step, owner_module) do
    Validation.validate_step_name!(owner_module, step.name, [:steps, :reduce])

    Validation.validate_required!(
      owner_module,
      step.over,
      [:steps, step.name, :over],
      "Workflow reduce steps require an `over` value."
    )

    Validation.validate_no_special_refs!(owner_module, [:steps, step.name, :over], step.over)
    Validation.validate_allowed_special_refs!(owner_module, [:steps, step.name, :input], step.params, [:items])
    Targets.validate_function!(owner_module, %{name: step.name, mfa: step.using})
    common = common_attrs!(owner_module, step, [:steps, step.name])

    Step.new!(
      [
        kind: :reduce,
        name: step.name,
        target: step.using,
        over: step.over,
        input: step.params || %{}
      ] ++ common
    )
  end

  defp common_attrs!(owner_module, step, path) do
    condition_when = Map.get(step, :when)
    condition_unless = Map.get(step, :unless)

    Validation.validate_no_special_refs!(owner_module, path ++ [:when], condition_when)
    Validation.validate_no_special_refs!(owner_module, path ++ [:unless], condition_unless)

    [
      after: step.after || [],
      condition_when: condition_when,
      condition_unless: condition_unless,
      retry: normalize_retry!(owner_module, Map.get(step, :retry), path ++ [:retry]),
      metadata: step.metadata || %{}
    ]
  end

  defp normalize_map_target!(owner_module, step) do
    case {Map.get(step, :function), Map.get(step, :action)} do
      {nil, nil} ->
        Error.raise!(
          owner_module,
          "Workflow map steps require exactly one target.",
          [:steps, step.name, :map],
          nil,
          "Declare either `function: {Module, :function, 2}` or `action: MyApp.Action`."
        )

      {function, nil} ->
        Targets.validate_function!(owner_module, %{name: step.name, mfa: function})
        {:function, function}

      {nil, action} ->
        Targets.validate_action!(owner_module, %{name: step.name, module: action})
        {:action, action}

      {function, action} ->
        Error.raise!(
          owner_module,
          "Workflow map steps cannot declare both function and action targets.",
          [:steps, step.name, :map],
          %{function: function, action: action},
          "Use exactly one of `function:` or `action:`."
        )
    end
  end

  defp normalize_retry!(_owner_module, nil, _path), do: nil

  defp normalize_retry!(owner_module, retry, path) do
    case RetryPolicy.new(retry) do
      {:ok, retry} ->
        retry

      {:error, reason} ->
        Error.raise!(
          owner_module,
          "Workflow step retry policy is invalid.",
          path,
          retry,
          "Use a policy like `[max_attempts: 3, backoff: [type: :exponential, min: 25, max: 250]]`. Cause: #{inspect(reason)}"
        )
    end
  end

  defp normalize_max_concurrency!(_owner_module, nil, _path), do: nil
  defp normalize_max_concurrency!(_owner_module, value, _path) when is_integer(value) and value > 0, do: value

  defp normalize_max_concurrency!(owner_module, value, path) do
    Error.raise!(
      owner_module,
      "Workflow map max_concurrency must be a positive integer.",
      path,
      value,
      "Use a value like `max_concurrency: 8`."
    )
  end
end
