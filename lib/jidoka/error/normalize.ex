defmodule Jidoka.Error.Normalize do
  @moduledoc false

  import Jidoka.Error.Normalize.Helpers

  alias Jidoka.Error.Normalize.{Basic, Runtime}

  @spec normalize(term(), keyword() | map()) :: Exception.t()
  def normalize(error, context) when is_exception(error) do
    if Jidoka.Error.normalized?(error) do
      error
    else
      execution_error("Jidoka execution failed.",
        phase: detail(context, :phase, :exception),
        details: details(context, %{reason: :exception, cause: error})
      )
    end
  end

  def normalize(reason, context) do
    with :error <- Basic.normalize(reason, context),
         :error <- Runtime.normalize(reason, context) do
      execution_error(detail(context, :message, "Jidoka execution failed."),
        phase: detail(context, :phase, :runtime),
        details: details(context, %{cause: reason})
      )
    else
      {:ok, error} -> error
    end
  end
end
