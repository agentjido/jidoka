defmodule Jidoka.Agent.Dsl.Sections.Contract do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Sections.Schedules

  @spec result_entity() :: Spark.Dsl.Entity.t()
  def result_entity do
    %Spark.Dsl.Entity{
      name: :result,
      target: Jidoka.Agent.Dsl.Result,
      args: [:schema],
      describe: """
      Configure the final structured result contract for this agent.
      """,
      schema: [
        schema: [
          type: :any,
          required: true,
          doc: "A Zoi object/map schema for the final agent response."
        ],
        repair: [
          type: :integer,
          required: false,
          as: :retries,
          default: 1,
          doc: "Number of final result repair attempts. Values above 3 are capped."
        ],
        on_validation_error: [
          type: {:in, [:repair, :error]},
          required: false,
          default: :repair,
          doc: "Whether invalid model output should be repaired once or returned as an error."
        ]
      ]
    }
  end

  @spec agent_entity() :: Spark.Dsl.Entity.t()
  def agent_entity do
    %Spark.Dsl.Entity{
      name: :agent,
      target: Jidoka.Agent.Dsl.Agent,
      args: [:id],
      singleton_entity_keys: [:result],
      describe: """
      Configure the immutable Jidoka agent contract.
      """,
      schema: [
        id: [
          type: :any,
          required: true,
          doc: "The stable public agent id. Must be lower snake case."
        ],
        model: [
          type: :any,
          required: false,
          default: :fast,
          doc: "The default model to use for this agent."
        ],
        instructions: [
          type: :any,
          required: false,
          doc: """
          Default instructions used for this agent.

          Supports a static string, a module implementing `resolve_system_prompt/1`,
          or an MFA tuple like `{MyApp.Prompts.Support, :build, ["prefix"]}`.
          """
        ],
        character: [
          type: :any,
          required: false,
          doc: """
          Optional structured character/persona source rendered before
          `instructions` in the effective system prompt.
          """
        ],
        description: [
          type: :string,
          required: false,
          doc: "Optional human-readable description for inspection and imported specs."
        ],
        context: [
          type: :any,
          required: false,
          doc: """
          Optional Zoi map/object schema for runtime context passed to `chat/3`.

          Defaults declared in the schema become the agent's default context.
          """
        ]
      ],
      entities: [
        result: [result_entity()],
        schedules: [Schedules.schedule_entity()]
      ]
    }
  end

  @spec section() :: Spark.Dsl.Section.t()
  def section do
    %Spark.Dsl.Section{
      name: :jidoka,
      top_level?: true,
      singleton_entity_keys: [:agent],
      describe: """
      Configure a Jidoka agent.
      """,
      entities: [agent_entity()]
    }
  end
end
