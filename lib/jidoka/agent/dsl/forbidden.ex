defmodule Jidoka.Agent.Dsl.Forbidden do
  @moduledoc false

  @block_messages %{
    defaults: "Move `model`, `instructions`, `character`, `context`, and `result` inside `agent :id do ... end`.",
    capabilities: "Use `tools do ... end`; `capabilities` is no longer accepted.",
    lifecycle:
      "Lifecycle callbacks, memory, compaction, timeouts, and schedules are runtime features now, not agent DSL.",
    memory: "Configure memory through runtime APIs or request/runtime configuration, not the agent DSL.",
    compaction: "Configure compaction through runtime APIs or `Jidoka.compact/2`, not the agent DSL.",
    skills: "Move skill declarations inside `tools do ... end`.",
    plugins: "Move plugin declarations inside `tools do ... end`.",
    subagents: "Move subagent declarations inside `tools do ... end`.",
    handoffs: "Move handoff declarations inside `tools do ... end`.",
    hooks: "Pass request hooks at runtime with `Jidoka.chat/3`; hooks are no longer agent DSL.",
    guardrails: "Use `controls do input/operation/result ... end`.",
    output: "Use `result` inside `agent :id do ... end`.",
    schedules: "Register schedules with `Jidoka.schedule/2` from application code, not the agent DSL."
  }

  @call_messages %{
    tool: "Use `tools do action MyApp.Action end` for deterministic operations.",
    schedule: "Register schedules with `Jidoka.schedule/2` from application code.",
    before_turn: "Pass request hooks at runtime with `Jidoka.chat/3`.",
    after_turn: "Pass request hooks at runtime with `Jidoka.chat/3`.",
    on_interrupt: "Pass request hooks at runtime with `Jidoka.chat/3`.",
    timeouts: "Lifecycle timeout DSL has been removed; use runtime APIs or defaults.",
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

    defmacro unquote(name)(arg, opts, do: _block) do
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
