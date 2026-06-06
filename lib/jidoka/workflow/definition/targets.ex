defmodule Jidoka.Workflow.Definition.Targets do
  @moduledoc false

  @spec validate_action!(module(), map()) :: :ok
  def validate_action!(owner_module, step) do
    cond do
      not is_atom(step.module) ->
        invalid_action!(owner_module, step)

      Code.ensure_loaded?(step.module) and function_exported?(step.module, :to_tool, 0) ->
        :ok

      Code.ensure_loaded?(step.module) ->
        invalid_action!(owner_module, step)

      true ->
        :ok
    end
  end

  @spec validate_function!(module(), map()) :: :ok
  def validate_function!(owner_module, %{mfa: {module, function, 2}} = step)
      when is_atom(module) and is_atom(function) do
    cond do
      Code.ensure_loaded?(module) and function_exported?(module, function, 2) ->
        :ok

      Code.ensure_loaded?(module) ->
        raise_error!(
          owner_module,
          "Workflow function step target is not exported.",
          [:steps, step.name, :function],
          {module, function, 2},
          "Use a `{module, function, 2}` tuple for a public function."
        )

      true ->
        :ok
    end
  end

  def validate_function!(owner_module, step) do
    raise_error!(
      owner_module,
      "Workflow function steps require a `{module, function, 2}` target.",
      [:steps, step.name, :function],
      step.mfa,
      "Use `function :normalize, {MyApp.WorkflowFns, :normalize, 2}, input: ...`."
    )
  end

  @spec validate_agent!(module(), map()) :: :ok
  def validate_agent!(owner_module, %{agent: module} = step) when is_atom(module) do
    cond do
      Code.ensure_loaded?(module) and function_exported?(module, :run_turn, 2) ->
        :ok

      Code.ensure_loaded?(module) ->
        raise_error!(
          owner_module,
          "Workflow agent step target is not a Jidoka-compatible agent.",
          [:steps, step.name, :agent],
          module,
          "Use a compiled Jidoka agent module exposing `run_turn/2`."
        )

      true ->
        :ok
    end
  end

  def validate_agent!(owner_module, step) do
    raise_error!(
      owner_module,
      "Workflow agent steps require a Jidoka agent module target.",
      [:steps, step.name, :agent],
      step.agent,
      "Use `agent :draft, MyApp.Agents.Writer, prompt: ...`."
    )
  end

  @spec invalid_action!(module(), map()) :: no_return()
  defp invalid_action!(owner_module, step) do
    raise_error!(
      owner_module,
      "Workflow action step target is not a valid action-backed module.",
      [:steps, step.name, :action],
      step.module,
      "Use a module defined with `use Jidoka.Action` or another Jido action module exposing `to_tool/0`."
    )
  end

  defp raise_error!(owner_module, message, path, value, hint) do
    raise Jidoka.Workflow.Dsl.Error.exception(
            message: message,
            path: path,
            value: value,
            hint: hint,
            module: owner_module
          )
  end
end
