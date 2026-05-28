defmodule Jidoka.Agent.Definition do
  @moduledoc false

  alias Jidoka.Agent.Compiler.{Context, Resolver}
  alias Jidoka.Agent.Compiler.Resolvers

  @type t :: map()

  @resolvers [
    Resolvers.Core,
    Resolvers.Controls,
    Resolvers.Tools,
    Resolvers.Runtime
  ]

  @spec build!(Macro.Env.t()) :: t()
  def build!(%Macro.Env{} = env) do
    env
    |> Context.new(owner_module: env.module)
    |> then(&Resolver.run(@resolvers, &1))
    |> case do
      {:ok, %Context{values: %{definition: definition}}} ->
        definition

      {:ok, %Context{}} ->
        raise ArgumentError, "Jidoka compiler resolvers did not produce a definition"

      {:error, {resolver, reason}} ->
        name = Resolver.name(resolver)
        raise ArgumentError, "Jidoka compiler resolver #{inspect(name)} failed: #{inspect(reason)}"
    end
  end

  @spec agent_contract!(module()) :: Jidoka.Agent.Dsl.Agent.t()
  def agent_contract!(owner_module) do
    case Spark.Dsl.Extension.get_entities(owner_module, [:jidoka]) do
      [%Jidoka.Agent.Dsl.Agent{} = agent] ->
        agent

      [] ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: "`agent :id do ... end` is required.",
                path: [:agent],
                hint: "Declare `agent :my_agent do instructions \"...\" end`.",
                module: owner_module
              )

      agents ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: "Only one `agent :id do ... end` block is allowed.",
                path: [:agent],
                value: Enum.map(agents, & &1.id),
                hint: "Merge the configuration into a single agent block.",
                module: owner_module
              )
    end
  end

  @doc false
  def section_entities(owner_module, path, predicate) when is_function(predicate, 1) do
    owner_module
    |> Spark.Dsl.Extension.get_entities(path)
    |> Enum.filter(predicate)
  end

  @doc false
  def guardrail_entities(owner_module, path) do
    section_entities(
      owner_module,
      path,
      &(match?(%Jidoka.Agent.Dsl.InputControl{}, &1) or
          match?(%Jidoka.Agent.Dsl.ResultControl{}, &1) or
          match?(%Jidoka.Agent.Dsl.OperationControl{}, &1))
    )
  end
end
