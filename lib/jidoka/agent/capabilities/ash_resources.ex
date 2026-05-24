defmodule Jidoka.Agent.AshResources do
  @moduledoc false

  @type t :: %{
          resources: [module()],
          tool_modules: [module()],
          tool_names: [String.t()],
          domain: module() | nil,
          require_actor?: boolean()
        }

  @spec validate_resource(module()) :: :ok | {:error, String.t()}
  def validate_resource(resource) when is_atom(resource) do
    cond do
      match?({:error, _}, Code.ensure_compiled(resource)) ->
        {:error, "Ash resource #{inspect(resource)} could not be loaded"}

      not Ash.Resource.Info.resource?(resource) ->
        {:error, "#{inspect(resource)} is not an Ash resource"}

      true ->
        with {:ok, _domain} <- domain(resource),
             {:ok, actions} <- actions(resource),
             {:ok, _names} <- Jidoka.Action.Adapter.action_names(actions) do
          :ok
        end
    end
  rescue
    error ->
      {:error, "failed to validate Ash resource #{inspect(resource)}: #{Exception.message(error)}"}
  end

  def validate_resource(other),
    do: {:error, "ash_resource entries must be modules, got: #{inspect(other)}"}

  @spec expand([module()]) :: {:ok, t()} | {:error, String.t()}
  def expand(resources) when is_list(resources) do
    Enum.reduce_while(resources, {:ok, initial_acc()}, fn resource, {:ok, acc} ->
      with :ok <- validate_resource(resource),
           {:ok, resource_domain} <- domain(resource),
           {:ok, resource_actions} <- actions(resource),
           {:ok, resource_tool_names} <- Jidoka.Action.Adapter.action_names(resource_actions),
           :ok <- ensure_same_domain(acc.domain, resource_domain),
           :ok <- ensure_no_duplicate_tool_names(acc.tool_names, resource_tool_names) do
        {:cont,
         {:ok,
          %{
            resources: acc.resources ++ [resource],
            tool_modules: acc.tool_modules ++ resource_actions,
            tool_names: acc.tool_names ++ resource_tool_names,
            domain: resource_domain,
            require_actor?: true
          }}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp initial_acc do
    %{resources: [], tool_modules: [], tool_names: [], domain: nil, require_actor?: false}
  end

  defp actions(resource) do
    case AshJido.Tools.actions(resource) do
      [] ->
        {:error,
         "Ash resource #{inspect(resource)} does not expose any AshJido actions; add a `jido do ... end` block first"}

      actions ->
        {:ok, actions}
    end
  end

  defp domain(resource) do
    case Ash.Resource.Info.domain(resource) do
      nil ->
        {:error, "Ash resource #{inspect(resource)} must declare a domain for Jidoka ash_resource tools"}

      domain ->
        {:ok, domain}
    end
  end

  defp ensure_same_domain(nil, _domain), do: :ok

  defp ensure_same_domain(domain, domain), do: :ok

  defp ensure_same_domain(expected, actual) do
    {:error,
     "Jidoka ash_resource tools must all belong to the same Ash domain; got #{inspect(expected)} and #{inspect(actual)}"}
  end

  defp ensure_no_duplicate_tool_names(existing, incoming) do
    duplicates =
      existing
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(incoming))
      |> MapSet.to_list()
      |> Enum.sort()

    if duplicates == [] do
      :ok
    else
      {:error, "duplicate tool names from ash_resource entries: #{Enum.join(duplicates, ", ")}"}
    end
  end
end
