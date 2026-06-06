defmodule Jidoka.Agent.ToolSources.Action do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Tool
  alias Jidoka.Agent.ToolSources.Common

  @spec action_modules(term()) :: [module()]
  def action_modules(%Tool{module: action}), do: [action]

  @spec operations!(term()) :: [Jidoka.Agent.Spec.Operation.t()]
  def operations!(%Tool{module: action}), do: [Common.operation_from_action!(action)]
end
