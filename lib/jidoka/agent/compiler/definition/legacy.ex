defmodule Jidoka.Agent.Definition.Legacy do
  @moduledoc false

  @legacy_sections [
    defaults: "Move `model`, `instructions`, and `character` inside `agent :id do ... end`.",
    memory: "Move `memory do ... end` inside `lifecycle do ... end`.",
    tools: "Move `tool`, `ash_resource`, and `mcp_tools` declarations inside `capabilities do ... end`.",
    skills: "Move `skill` and `load_path` declarations inside `capabilities do ... end`.",
    plugins: "Move `plugin` declarations inside `capabilities do ... end`.",
    subagents: "Move `subagent` declarations inside `capabilities do ... end`.",
    handoffs: "Move `handoff` declarations inside `capabilities do ... end`.",
    hooks: "Move hook declarations inside `lifecycle do ... end`.",
    guardrails:
      "Move guardrails inside `lifecycle do ... end` and rename `input`, `output`, and `tool` to `input_guardrail`, `output_guardrail`, and `tool_guardrail`."
  ]

  @spec reject_legacy_placements!(module()) :: :ok
  def reject_legacy_placements!(owner_module) do
    Enum.each(@legacy_sections, fn {section, hint} ->
      if legacy_section_present?(owner_module, section) do
        raise Jidoka.Agent.Dsl.Error.exception(
                message: "Top-level `#{section} do ... end` is not valid in the beta Jidoka DSL.",
                path: [section],
                hint: hint,
                module: owner_module,
                location: Spark.Dsl.Extension.get_section_anno(owner_module, [section])
              )
      end
    end)
  end

  defp legacy_section_present?(owner_module, section) do
    Spark.Dsl.Extension.get_entities(owner_module, [section]) != [] or
      not is_nil(Spark.Dsl.Extension.get_section_anno(owner_module, [section]))
  rescue
    _ -> false
  end
end
