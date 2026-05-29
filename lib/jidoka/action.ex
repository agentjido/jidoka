defmodule Jidoka.Action do
  @moduledoc """
  Minimal Jidoka wrapper around `Jido.Action`.

  This keeps tool authoring on Jido's action/runtime structure while Jidoka
  handles LLM-facing operation planning.
  """

  @doc false
  defmacro __using__(opts \\ []) do
    module_name =
      __CALLER__.module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    defaults = [
      name: module_name,
      description: "Jidoka action #{module_name}"
    ]

    quote location: :keep do
      use Jido.Action, unquote(Keyword.merge(defaults, opts))
    end
  end
end
