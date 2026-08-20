defmodule JidokaExamples.IncidentRecoveryCommander.Scenario do
  @moduledoc false

  alias JidokaExamples.IncidentRecoveryCommander.Scenarios.{AsyncControls, Command}

  def run(opts \\ []) do
    with {:ok, command} <- command(opts),
         {:ok, stream} <- stream_brief(opts),
         {:ok, cancellation} <- cancellation_drill(opts) do
      {:ok, %{cancellation: cancellation, command: command, stream: stream}}
    end
  end

  def command(opts \\ []), do: Command.run(opts)
  def stream_brief(opts \\ []), do: AsyncControls.stream(opts)
  def cancellation_drill(opts \\ []), do: AsyncControls.cancel(opts)
end
