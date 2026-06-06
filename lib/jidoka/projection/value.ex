defmodule Jidoka.Projection.Value do
  @moduledoc false

  alias Jidoka.Error

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

  def project(%{} = map), do: Map.new(map, fn {key, value} -> {key, project(value)} end)
  def project(list) when is_list(list), do: Enum.map(list, &project/1)
  def project(value), do: value

  defp zoi_schema?(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Zoi.Types.")
  end
end
