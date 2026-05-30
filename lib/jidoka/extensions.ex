defmodule Jidoka.Extensions do
  @moduledoc """
  Registry for built-in Jidoka extensions.

  Extensions are regular modules that contribute narrow contracts. The registry
  is intentionally explicit so extension order and capability surfaces stay
  reviewable.
  """

  @builtins [Jidoka.Extensions.Trace]

  @doc "Returns built-in extension modules."
  @spec builtins() :: [module()]
  def builtins, do: @builtins

  @doc "Returns a compact description of registered extensions."
  @spec describe([module()]) :: [map()]
  def describe(extensions \\ @builtins) when is_list(extensions) do
    Enum.map(extensions, fn extension ->
      %{
        module: extension,
        name: extension.name(),
        dsl_sections: length(extension.dsl_sections()),
        verifiers: extension.verifiers(),
        workflow_steps: :contributes_on_plan,
        runtime_requirements: :contributes_on_spec,
        events: extension.events()
      }
    end)
  end
end
