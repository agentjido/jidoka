defmodule Jidoka.Agent.Dsl.Forbidden do
  @moduledoc false

  @block_messages %{
    defaults: "Move `model`, `instructions`, `character`, `context`, and `result` inside `agent :id do ... end`.",
    memory: "Move memory configuration inside `lifecycle do ... end`.",
    skills: "Move skill declarations inside `capabilities do ... end`.",
    plugins: "Move plugin declarations inside `capabilities do ... end`.",
    subagents: "Move subagent declarations inside `capabilities do ... end`.",
    handoffs: "Move handoff declarations inside `capabilities do ... end`.",
    hooks: "Use `controls do ... end` for policy and keep lifecycle callbacks inside `lifecycle do ... end`.",
    guardrails: "Use `controls do input/operation/result ... end`.",
    output: "Use `result` inside `agent :id do ... end`."
  }

  @call_messages %{
    tool: "Use `tools do action MyApp.Action end` for deterministic operations.",
    input_guardrail: "Use `controls do input MyApp.Control end`.",
    output_guardrail: "Use `controls do result MyApp.Control end`.",
    tool_guardrail: "Use `controls do operation MyApp.Control end`."
  }

  @messages Map.merge(@block_messages, @call_messages)

  for {name, _message} <- @block_messages do
    defmacro unquote(name)(opts \\ [], do: _block) do
      reject!(unquote(name), __CALLER__, :block, opts)
    end
  end

  for {name, _message} <- @call_messages do
    defmacro unquote(name)(opts) do
      reject!(unquote(name), __CALLER__, :call, opts)
    end

    defmacro unquote(name)(arg, opts) do
      reject!(unquote(name), __CALLER__, :call, {arg, opts})
    end
  end

  def reject!(name, caller, kind, _opts) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "#{prefix(name, kind)} is not valid in the Jidoka V3 DSL. #{Map.fetch!(@messages, name)}"
  end

  defp prefix(name, :block), do: "Top-level `#{name} do ... end`"
  defp prefix(name, :call), do: "`#{name}`"
end
