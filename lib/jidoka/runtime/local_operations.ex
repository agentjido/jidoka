defmodule Jidoka.Runtime.LocalOperations do
  @moduledoc """
  Runtime support for executing local Elixir functions as Jidoka operations.

  This is mainly useful for deterministic tests, examples, and simple in-process
  operations. Production tool authoring should normally use `Jidoka.Action`,
  which is backed by `Jido.Action`.
  """

  alias Jidoka.Effect
  alias Jidoka.Schema

  @type handler ::
          (map() -> term())
          | (Effect.Intent.t(), Effect.Journal.t() -> term())

  @doc """
  Builds an operation function from a map of operation handlers.

      operations =
        Jidoka.Runtime.LocalOperations.operations(%{
          "local_time" => fn %{"city" => city} -> {:ok, %{city: city, time: "09:30"}} end
        })
  """
  @spec operations(%{required(String.t() | atom()) => handler()}) ::
          Jidoka.Runtime.Capabilities.operation_capability()
  def operations(handlers) when is_map(handlers) do
    handlers = Map.new(handlers, fn {name, fun} -> {to_string(name), fun} end)

    fn
      %Effect.Intent{kind: :operation, payload: payload} = intent, %Effect.Journal{} = journal ->
        with {:ok, name} <- Schema.fetch_key(payload, :name),
             {:ok, handler} <- fetch_handler(handlers, name) do
          call_handler(handler, intent, journal)
        end

      %Effect.Intent{kind: kind}, _journal ->
        {:error, {:unsupported_effect_kind, kind}}
    end
  end

  defp fetch_handler(handlers, name) do
    case Map.fetch(handlers, to_string(name)) do
      {:ok, handler} -> {:ok, handler}
      :error -> {:error, {:missing_operation_handler, name}}
    end
  end

  defp call_handler(handler, %Effect.Intent{} = intent, %Effect.Journal{} = journal)
       when is_function(handler, 2) do
    handler
    |> apply([intent, journal])
    |> normalize_result()
  end

  defp call_handler(handler, %Effect.Intent{} = intent, _journal) when is_function(handler, 1) do
    handler
    |> apply([Schema.get_key(intent.payload, :arguments, %{})])
    |> normalize_result()
  end

  defp call_handler(handler, _intent, _journal),
    do: {:error, {:invalid_operation_handler, handler}}

  defp normalize_result({:ok, _value} = result), do: result
  defp normalize_result({:error, _reason} = result), do: result
  defp normalize_result(value), do: {:ok, value}
end
