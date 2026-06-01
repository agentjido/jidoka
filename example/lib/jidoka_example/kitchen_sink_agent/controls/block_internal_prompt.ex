defmodule JidokaExample.KitchenSinkAgent.Controls.BlockInternalPrompt do
  @moduledoc false

  use Jidoka.Control, name: "block_internal_prompt"

  @blocked_terms ["classified", "internal secret"]

  @impl true
  def call(%{boundary: :input, input: input}) when is_binary(input) do
    normalized = String.downcase(input)

    if Enum.any?(@blocked_terms, &String.contains?(normalized, &1)) do
      {:block, :internal_prompt_blocked}
    else
      :allow
    end
  end

  def call(_context), do: :allow
end
