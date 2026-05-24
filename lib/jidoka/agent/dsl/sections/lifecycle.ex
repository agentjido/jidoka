defmodule Jidoka.Agent.Dsl.Sections.Lifecycle do
  @moduledoc false

  alias Jidoka.Agent.Dsl.{
    AfterTurnHook,
    BeforeTurnHook,
    InterruptHook
  }

  alias Jidoka.Agent.Dsl.Sections.{Compaction, Memory}

  @spec before_turn_hook_entity() :: Spark.Dsl.Entity.t()
  def before_turn_hook_entity do
    %Spark.Dsl.Entity{
      name: :before_turn,
      describe: """
      Register a hook that runs before a Jidoka chat turn starts.
      """,
      target: BeforeTurnHook,
      args: [:hook],
      schema: [
        hook: [
          type: :any,
          required: true,
          doc: "A Jidoka.Hook module or MFA tuple."
        ]
      ]
    }
  end

  @spec after_turn_hook_entity() :: Spark.Dsl.Entity.t()
  def after_turn_hook_entity do
    %Spark.Dsl.Entity{
      name: :after_turn,
      describe: """
      Register a hook that runs after a Jidoka chat turn completes.
      """,
      target: AfterTurnHook,
      args: [:hook],
      schema: [
        hook: [
          type: :any,
          required: true,
          doc: "A Jidoka.Hook module or MFA tuple."
        ]
      ]
    }
  end

  @spec interrupt_hook_entity() :: Spark.Dsl.Entity.t()
  def interrupt_hook_entity do
    %Spark.Dsl.Entity{
      name: :on_interrupt,
      describe: """
      Register a hook that runs when a Jidoka turn interrupts.
      """,
      target: InterruptHook,
      args: [:hook],
      schema: [
        hook: [
          type: :any,
          required: true,
          doc: "A Jidoka.Hook module or MFA tuple."
        ]
      ]
    }
  end

  @spec section() :: Spark.Dsl.Section.t()
  def section do
    %Spark.Dsl.Section{
      name: :lifecycle,
      describe: """
      Configure per-turn lifecycle policies for this agent.
      """,
      entities: [
        before_turn_hook_entity(),
        after_turn_hook_entity(),
        interrupt_hook_entity()
      ],
      sections: [Memory.section(), Compaction.section()]
    }
  end
end
