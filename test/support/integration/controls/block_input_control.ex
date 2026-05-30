defmodule Jidoka.IntegrationSupport.BlockInputControl do
  @moduledoc false

  use Jidoka.Control, name: "block_input_control"

  @impl true
  def call(%{input: input}) do
    if String.contains?(input, "blocked") do
      {:block, :blocked_input}
    else
      :allow
    end
  end
end
