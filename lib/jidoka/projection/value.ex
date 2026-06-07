defmodule Jidoka.Projection.Value do
  @moduledoc false

  alias Jidoka.Error

  @sensitive_words ~w(authorization credential credentials password secret token)
  @sensitive_compounds ~w(apikey privatekey)

  @spec project(term()) :: term()
  def project(%_{} = exception) when is_exception(exception), do: Error.to_map(exception)

  def project(%LLMDB.Model{} = model), do: Jidoka.Config.model_ref(model)

  def project(%module{} = struct) do
    if zoi_schema?(module) do
      %{schema?: true}
    else
      struct
      |> Map.from_struct()
      |> project()
    end
  end

  def project(%{} = map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, project(value)}
      end
    end)
  end

  def project(list) when is_list(list), do: Enum.map(list, &project/1)
  def project(value), do: value

  defp zoi_schema?(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Zoi.Types.")
  end

  defp sensitive_key?(key) when is_atom(key), do: key |> Atom.to_string() |> sensitive_key?()

  defp sensitive_key?(key) when is_binary(key) do
    normalized = key |> Macro.underscore() |> String.downcase()
    words = String.split(normalized, ~r/[^a-z0-9]+/, trim: true)

    Enum.join(words, "") in @sensitive_compounds or
      Enum.any?(words, &(&1 in @sensitive_words))
  end

  defp sensitive_key?(_key), do: false
end
