defmodule Jidoka.Approval do
  @moduledoc """
  Helpers for human-in-the-loop approval controls.

  Approval is a named convenience over Jidoka interrupts. A control can return
  `Jidoka.Approval.request/2` to pause the turn and hand the caller a structured
  `%Jidoka.Interrupt{kind: :approval}`.

      def call(input) do
        if risky?(input) do
          Jidoka.Approval.request("Approve this operation.", data: %{amount: 10_000})
        else
          :cont
        end
      end
  """

  alias Jidoka.Interrupt

  @type data :: map() | keyword()

  @doc """
  Builds a control return value that pauses the turn for approval.
  """
  @spec request(String.t(), keyword()) :: {:interrupt, Interrupt.t()}
  def request(message, opts \\ []) when is_binary(message) and is_list(opts) do
    data =
      opts
      |> Keyword.get(:data, %{})
      |> normalize_data()

    {:interrupt,
     Interrupt.new(
       kind: Keyword.get(opts, :kind, :approval),
       message: message,
       data: data
     )}
  end

  defp normalize_data(data) when is_map(data), do: data
  defp normalize_data(data) when is_list(data), do: Map.new(data)
end
