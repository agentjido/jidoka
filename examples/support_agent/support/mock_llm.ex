defmodule JidokaExamples.SupportAgent.LLMs.MockLLM do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Schema

  def new(order_id \\ "A1001", observer \\ nil) do
    fn %Effect.Intent{kind: :llm, payload: payload}, %Effect.Journal{}, _context ->
      case tool_observation(payload, "lookup_order") do
        nil ->
          {:ok,
           %{
             type: :operation,
             name: "lookup_order",
             arguments: %{"order_id" => order_id}
           }}

        order ->
          notify(observer, {:order_observation_seen, order})

          {:ok,
           %{
             type: :final,
             content: final_content(order)
           }}
      end
    end
  end

  defp tool_observation(payload, operation) do
    payload
    |> Schema.get_key(:prompt)
    |> Schema.get_key(:messages)
    |> Enum.find_value(fn message ->
      if Schema.get_key(message, :role) == :tool and
           Schema.get_key(message, :operation) == operation do
        Schema.get_key(message, :output)
      end
    end)
  end

  defp format_status(status), do: status |> to_string() |> String.replace("_", " ")

  defp final_content(order) do
    if Schema.get_key(order, :status) == "not_found" do
      "Order #{Schema.get_key(order, :order_id)} was not found. " <>
        "#{Schema.get_key(order, :recommended_action)}"
    else
      "Order #{Schema.get_key(order, :order_id)} is " <>
        "#{format_status(Schema.get_key(order, :status))} with " <>
        "#{Schema.get_key(order, :carrier)}. ETA: #{Schema.get_key(order, :eta)}. " <>
        "#{Schema.get_key(order, :recommended_action)}"
    end
  end

  defp notify(observer, message) when is_pid(observer), do: send(observer, message)
  defp notify(_observer, _message), do: :ok
end
