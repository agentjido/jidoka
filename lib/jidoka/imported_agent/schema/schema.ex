defmodule Jidoka.ImportedAgent.Spec.Schema do
  @moduledoc false
  @id_schema [
    Zoi.string()
    |> Zoi.trim()
    |> Zoi.min(1)
    |> Zoi.max(64)
    |> Zoi.regex(~r/^[a-z][a-z0-9_]*$/)
  ]

  @instructions_schema [
    Zoi.string()
    |> Zoi.min(1)
    |> Zoi.max(50_000)
  ]

  @character_name_schema Zoi.string()
                         |> Zoi.trim()
                         |> Zoi.min(1)
                         |> Zoi.max(128)

  @tool_name_schema Zoi.string()
                    |> Zoi.trim()
                    |> Zoi.min(1)
                    |> Zoi.max(128)
                    |> Zoi.regex(~r/^[a-z][a-z0-9_]*$/)

  @plugin_name_schema Zoi.string()
                      |> Zoi.trim()
                      |> Zoi.min(1)
                      |> Zoi.max(128)
                      |> Zoi.regex(~r/^[a-z][a-z0-9_]*$/)

  @subagent_agent_name_schema Zoi.string()
                              |> Zoi.trim()
                              |> Zoi.min(1)
                              |> Zoi.max(128)
                              |> Zoi.regex(~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/)

  @subagent_tool_name_schema Zoi.string()
                             |> Zoi.trim()
                             |> Zoi.min(1)
                             |> Zoi.max(128)
                             |> Zoi.regex(~r/^[a-z][a-z0-9_]*$/)

  @workflow_name_schema Zoi.string()
                        |> Zoi.trim()
                        |> Zoi.min(1)
                        |> Zoi.max(128)
                        |> Zoi.regex(~r/^[a-z][a-z0-9_]*$/)

  @workflow_tool_name_schema Zoi.string()
                             |> Zoi.trim()
                             |> Zoi.min(1)
                             |> Zoi.max(128)
                             |> Zoi.regex(~r/^[a-z][a-z0-9_]*$/)

  @handoff_agent_name_schema @subagent_agent_name_schema
  @handoff_tool_name_schema @subagent_tool_name_schema

  @web_mode_schema Zoi.string()
                   |> Zoi.trim()
                   |> Zoi.min(1)

  @subagent_forward_context_key_schema Zoi.union([
                                         Zoi.string() |> Zoi.trim() |> Zoi.min(1),
                                         Zoi.atom()
                                       ])

  @subagent_forward_context_schema Zoi.union([
                                     Zoi.string() |> Zoi.trim() |> Zoi.min(1),
                                     Zoi.object(
                                       %{
                                         mode:
                                           Zoi.string()
                                           |> Zoi.trim()
                                           |> Zoi.min(1),
                                         keys:
                                           Zoi.list(@subagent_forward_context_key_schema)
                                           |> Zoi.optional()
                                       },
                                       coerce: true,
                                       unrecognized_keys: :error
                                     )
                                   ])

  @workflow_forward_context_schema @subagent_forward_context_schema
  @handoff_forward_context_schema @subagent_forward_context_schema

  @hook_name_schema Zoi.string()
                    |> Zoi.trim()
                    |> Zoi.min(1)
                    |> Zoi.max(128)
                    |> Zoi.regex(~r/^[a-z][a-z0-9_]*$/)

  @skill_name_schema Zoi.string()
                     |> Zoi.trim()
                     |> Zoi.min(1)
                     |> Zoi.max(128)
                     |> Zoi.regex(~r/^[a-z0-9]+(-[a-z0-9]+)*$/)

  @skill_path_schema Zoi.string()
                     |> Zoi.trim()
                     |> Zoi.min(1)
                     |> Zoi.max(4_096)

  @mcp_endpoint_schema Zoi.string()
                       |> Zoi.trim()
                       |> Zoi.min(1)
                       |> Zoi.max(128)

  @guardrail_name_schema Zoi.string()
                         |> Zoi.trim()
                         |> Zoi.min(1)
                         |> Zoi.max(128)
                         |> Zoi.regex(~r/^[a-z][a-z0-9_]*$/)

  @default_hooks %{before_turn: [], after_turn: [], on_interrupt: []}
  @default_guardrails %{input: [], output: [], tool: []}
  @default_subagents []
  @default_workflows []
  @default_handoffs []
  @default_web []
  @default_skills []
  @default_skill_paths []
  @default_mcp_tools []

  @model_map_schema Zoi.object(
                      %{
                        provider:
                          Zoi.string()
                          |> Zoi.trim()
                          |> Zoi.min(1)
                          |> Zoi.max(64),
                        id:
                          Zoi.string()
                          |> Zoi.trim()
                          |> Zoi.min(1)
                          |> Zoi.max(256),
                        base_url:
                          Zoi.string()
                          |> Zoi.trim()
                          |> Zoi.min(1)
                          |> Zoi.max(2_048)
                          |> Zoi.optional()
                      },
                      coerce: true,
                      unrecognized_keys: :error
                    )

  @hooks_schema Zoi.object(
                  %{
                    before_turn: Zoi.list(@hook_name_schema) |> Zoi.default([]),
                    after_turn: Zoi.list(@hook_name_schema) |> Zoi.default([]),
                    on_interrupt: Zoi.list(@hook_name_schema) |> Zoi.default([])
                  },
                  coerce: true,
                  unrecognized_keys: :error
                )

  @subagent_schema Zoi.object(
                     %{
                       agent: @subagent_agent_name_schema,
                       as: @subagent_tool_name_schema |> Zoi.optional(),
                       description:
                         Zoi.string()
                         |> Zoi.trim()
                         |> Zoi.min(1)
                         |> Zoi.max(1_000)
                         |> Zoi.optional(),
                       target:
                         Zoi.string()
                         |> Zoi.trim()
                         |> Zoi.min(1)
                         |> Zoi.default("ephemeral"),
                       peer_id:
                         Zoi.string()
                         |> Zoi.trim()
                         |> Zoi.min(1)
                         |> Zoi.optional(),
                       peer_id_context_key:
                         Zoi.union([Zoi.string() |> Zoi.trim() |> Zoi.min(1), Zoi.atom()])
                         |> Zoi.optional(),
                       timeout_ms: Zoi.integer() |> Zoi.optional(),
                       forward_context: @subagent_forward_context_schema |> Zoi.optional(),
                       result:
                         Zoi.string()
                         |> Zoi.trim()
                         |> Zoi.min(1)
                         |> Zoi.optional()
                     },
                     coerce: true,
                     unrecognized_keys: :error
                   )

  @workflow_schema Zoi.union([
                     @workflow_name_schema,
                     Zoi.object(
                       %{
                         workflow: @workflow_name_schema,
                         as: @workflow_tool_name_schema |> Zoi.optional(),
                         description:
                           Zoi.string()
                           |> Zoi.trim()
                           |> Zoi.min(1)
                           |> Zoi.max(1_000)
                           |> Zoi.optional(),
                         timeout: Zoi.integer() |> Zoi.optional(),
                         forward_context: @workflow_forward_context_schema |> Zoi.optional(),
                         result:
                           Zoi.string()
                           |> Zoi.trim()
                           |> Zoi.min(1)
                           |> Zoi.optional()
                       },
                       coerce: true,
                       unrecognized_keys: :error
                     )
                   ])

  @handoff_schema Zoi.union([
                    @handoff_agent_name_schema,
                    Zoi.object(
                      %{
                        agent: @handoff_agent_name_schema,
                        as: @handoff_tool_name_schema |> Zoi.optional(),
                        description:
                          Zoi.string()
                          |> Zoi.trim()
                          |> Zoi.min(1)
                          |> Zoi.max(1_000)
                          |> Zoi.optional(),
                        target:
                          Zoi.string()
                          |> Zoi.trim()
                          |> Zoi.min(1)
                          |> Zoi.default("auto"),
                        peer_id:
                          Zoi.string()
                          |> Zoi.trim()
                          |> Zoi.min(1)
                          |> Zoi.optional(),
                        peer_id_context_key:
                          Zoi.union([Zoi.string() |> Zoi.trim() |> Zoi.min(1), Zoi.atom()])
                          |> Zoi.optional(),
                        forward_context: @handoff_forward_context_schema |> Zoi.optional()
                      },
                      coerce: true,
                      unrecognized_keys: :error
                    )
                  ])

  @web_schema Zoi.union([
                @web_mode_schema,
                Zoi.object(
                  %{
                    mode: @web_mode_schema
                  },
                  coerce: true,
                  unrecognized_keys: :error
                )
              ])

  @guardrails_schema Zoi.object(
                       %{
                         input: Zoi.list(@guardrail_name_schema) |> Zoi.default([]),
                         output: Zoi.list(@guardrail_name_schema) |> Zoi.default([]),
                         tool: Zoi.list(@guardrail_name_schema) |> Zoi.default([])
                       },
                       coerce: true,
                       unrecognized_keys: :error
                     )

  @mcp_tool_schema Zoi.object(
                     %{
                       endpoint: @mcp_endpoint_schema,
                       prefix:
                         Zoi.string()
                         |> Zoi.trim()
                         |> Zoi.min(1)
                         |> Zoi.max(128)
                         |> Zoi.optional(),
                       required:
                         Zoi.boolean()
                         |> Zoi.optional()
                     },
                     coerce: true,
                     unrecognized_keys: :error
                   )

  @memory_retrieve_schema Zoi.object(
                            %{
                              limit: Zoi.integer() |> Zoi.default(5)
                            },
                            coerce: true,
                            unrecognized_keys: :error
                          )

  @memory_schema Zoi.object(
                   %{
                     mode:
                       Zoi.string()
                       |> Zoi.trim()
                       |> Zoi.min(1)
                       |> Zoi.default("conversation"),
                     namespace:
                       Zoi.string()
                       |> Zoi.trim()
                       |> Zoi.min(1)
                       |> Zoi.default("per_agent"),
                     shared_namespace:
                       Zoi.string()
                       |> Zoi.trim()
                       |> Zoi.min(1)
                       |> Zoi.optional(),
                     context_namespace_key:
                       Zoi.union([Zoi.string() |> Zoi.trim() |> Zoi.min(1), Zoi.atom()])
                       |> Zoi.optional(),
                     capture:
                       Zoi.string()
                       |> Zoi.trim()
                       |> Zoi.min(1)
                       |> Zoi.default("conversation"),
                     retrieve: @memory_retrieve_schema |> Zoi.default(%{limit: 5}),
                     inject:
                       Zoi.string()
                       |> Zoi.trim()
                       |> Zoi.min(1)
                       |> Zoi.default("instructions")
                   },
                   coerce: true,
                   unrecognized_keys: :error
                 )

  @compaction_schema Zoi.object(
                       %{
                         mode:
                           Zoi.string()
                           |> Zoi.trim()
                           |> Zoi.min(1)
                           |> Zoi.default("auto"),
                         strategy:
                           Zoi.string()
                           |> Zoi.trim()
                           |> Zoi.min(1)
                           |> Zoi.default("summary"),
                         max_messages: Zoi.integer() |> Zoi.default(40),
                         keep_last: Zoi.integer() |> Zoi.default(12),
                         max_summary_chars: Zoi.integer() |> Zoi.default(4_000),
                         prompt:
                           Zoi.string()
                           |> Zoi.trim()
                           |> Zoi.min(1)
                           |> Zoi.max(20_000)
                           |> Zoi.optional()
                       },
                       coerce: true,
                       unrecognized_keys: :error
                     )

  @model_schema Zoi.union([
                  Zoi.string() |> Zoi.trim() |> Zoi.min(1) |> Zoi.max(256),
                  @model_map_schema
                ])

  @output_schema Zoi.object(
                   %{
                     schema: Zoi.map(),
                     retries: Zoi.integer() |> Zoi.default(1),
                     on_validation_error:
                       Zoi.string()
                       |> Zoi.trim()
                       |> Zoi.min(1)
                       |> Zoi.default("repair")
                   },
                   coerce: true,
                   unrecognized_keys: :error
                 )

  @agent_schema Zoi.object(
                  %{
                    id: hd(@id_schema),
                    description:
                      Zoi.string()
                      |> Zoi.trim()
                      |> Zoi.min(1)
                      |> Zoi.max(1_000)
                      |> Zoi.optional(),
                    context: Zoi.map() |> Zoi.default(%{})
                  },
                  coerce: true,
                  unrecognized_keys: :error
                )

  @defaults_schema Zoi.object(
                     %{
                       model: @model_schema |> Zoi.default("fast"),
                       instructions: hd(@instructions_schema),
                       character: Zoi.union([@character_name_schema, Zoi.map()]) |> Zoi.optional()
                     },
                     coerce: true,
                     unrecognized_keys: :error
                   )

  @capabilities_schema Zoi.object(
                         %{
                           tools: Zoi.list(@tool_name_schema) |> Zoi.default([]),
                           skills: Zoi.list(@skill_name_schema) |> Zoi.default(@default_skills),
                           skill_paths: Zoi.list(@skill_path_schema) |> Zoi.default(@default_skill_paths),
                           mcp_tools: Zoi.list(@mcp_tool_schema) |> Zoi.default(@default_mcp_tools),
                           subagents: Zoi.list(@subagent_schema) |> Zoi.default(@default_subagents),
                           workflows: Zoi.list(@workflow_schema) |> Zoi.default(@default_workflows),
                           handoffs: Zoi.list(@handoff_schema) |> Zoi.default(@default_handoffs),
                           web: Zoi.list(@web_schema) |> Zoi.default(@default_web),
                           plugins: Zoi.list(@plugin_name_schema) |> Zoi.default([])
                         },
                         coerce: true,
                         unrecognized_keys: :error
                       )

  @lifecycle_schema Zoi.object(
                      %{
                        memory: Zoi.union([@memory_schema, Zoi.literal(nil)]) |> Zoi.default(nil),
                        compaction: Zoi.union([@compaction_schema, Zoi.literal(nil)]) |> Zoi.default(nil),
                        hooks: @hooks_schema |> Zoi.default(@default_hooks),
                        guardrails: @guardrails_schema |> Zoi.default(@default_guardrails)
                      },
                      coerce: true,
                      unrecognized_keys: :error
                    )

  @schema Zoi.object(
            %{
              agent: @agent_schema,
              defaults: @defaults_schema,
              capabilities: @capabilities_schema |> Zoi.default(%{}),
              lifecycle: @lifecycle_schema |> Zoi.default(%{}),
              output: Zoi.union([@output_schema, Zoi.literal(nil)]) |> Zoi.default(nil)
            },
            coerce: true,
            unrecognized_keys: :error
          )

  @spec schema() :: Zoi.schema()
  def schema, do: @schema
end
