defmodule Jidoka.Controls.MaxInputLength do
  @moduledoc """
  Built-in input-size control.

  Configure with `metadata: %{max: 8_000}`. The control can run at any boundary,
  but it evaluates the original turn input.
  """

  use Jidoka.Control, name: "max_input_length"

  @impl true
  def call(context) do
    with {:ok, ctx} <- runtime_context(context),
         {:ok, max} <- max_length(context) do
      length = String.length(ctx.input || "")

      if length <= max do
        :cont
      else
        {:block, {:input_too_long, length, max}}
      end
    end
  end

  defp runtime_context(%{ctx: %Jidoka.Context{} = ctx}), do: {:ok, ctx}
  defp runtime_context(%Jidoka.Context{} = ctx), do: {:ok, ctx}
  defp runtime_context(_context), do: {:error, :missing_jidoka_context}

  defp max_length(%{metadata: metadata}), do: max_length(metadata)

  defp max_length(metadata) when is_map(metadata) do
    metadata
    |> get_any([:max, "max", :max_length, "max_length"])
    |> normalize_max()
  end

  defp max_length(_metadata), do: {:error, :missing_max_input_length}

  defp normalize_max(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_max(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, {:invalid_max_input_length, value}}
    end
  end

  defp normalize_max(value), do: {:error, {:invalid_max_input_length, value}}

  defp get_any(map, keys), do: Enum.find_value(keys, &Map.get(map, &1))
end
