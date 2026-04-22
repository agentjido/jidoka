defmodule Mix.Tasks.EvalMvp do
  use Mix.Task

  alias Jidoka.Hardening.EvaluationCommand

  @shortdoc "Run the MVP end-to-end fixture corpus through public runtime APIs."

  @moduledoc """
  Run the hardening evaluation fixtures.

  Example:

      mix eval_mvp
  """

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    case EvaluationCommand.run() do
      {:ok, _results} ->
        :ok

      {:error, reason, _results} ->
        Mix.raise(reason)
    end
  end
end
