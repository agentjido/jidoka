defmodule Jidoka.Agent.Dsl.Forbidden do
  @moduledoc false

  @messages %{
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

  for {name, _message} <- @messages do
    defmacro unquote(name)(opts \\ [], do: _block) do
      reject!(unquote(name), __CALLER__, opts)
    end
  end

  def reject!(name, caller, _opts) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "Top-level `#{name} do ... end` is not valid in the Jidoka V3 DSL. #{Map.fetch!(@messages, name)}"
  end
end
