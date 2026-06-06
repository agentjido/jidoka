defmodule Jidoka.Workflow.Definition.Error do
  @moduledoc false

  @spec raise!(module(), String.t(), [term()], term(), String.t()) :: no_return()
  def raise!(owner_module, message, path, value, hint) do
    raise Jidoka.Workflow.Dsl.Error.exception(
            message: message,
            path: path,
            value: value,
            hint: hint,
            module: owner_module
          )
  end
end
