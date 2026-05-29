defmodule Jidoka.Runtime.Signals do
  @moduledoc "Signal constructors for the Jidoka/Jido AgentServer boundary."

  @turn_run_type "jidoka.turn.run"

  @spec turn_run_type() :: String.t()
  def turn_run_type, do: @turn_run_type

  @spec turn_run(String.t(), keyword()) :: Jido.Signal.t()
  def turn_run(input, opts \\ []) when is_binary(input) and is_list(opts) do
    data =
      %{
        input: input,
        runtime_opts: Keyword.get(opts, :runtime_opts, [])
      }
      |> maybe_put(:request_id, Keyword.get(opts, :request_id))
      |> maybe_put(:context, Keyword.get(opts, :context))
      |> maybe_put(:metadata, Keyword.get(opts, :metadata))

    Jido.Signal.new!(@turn_run_type, data, source: "/jidoka")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
