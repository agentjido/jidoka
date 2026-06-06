defmodule Jidoka.Agent.ServerOptions do
  @moduledoc false

  @spec child_opts(module(), keyword() | map()) :: keyword() | map()
  def child_opts(agent_module, opts) when is_atom(agent_module) and is_list(opts) do
    opts
    |> Keyword.put_new(:agent, agent_module)
    |> Keyword.put_new(:jido, Jidoka.Jido)
    |> Keyword.put_new(:id, default_agent_id(agent_module))
  end

  def child_opts(agent_module, opts) when is_atom(agent_module) and is_map(opts) do
    opts
    |> Map.put_new(:agent, agent_module)
    |> Map.put_new(:jido, Jidoka.Jido)
    |> Map.put_new(:id, default_agent_id(agent_module))
  end

  defp default_agent_id(agent_module) do
    if Code.ensure_loaded?(agent_module) and function_exported?(agent_module, :__jidoka_agent_id__, 0) do
      agent_module.__jidoka_agent_id__()
    else
      agent_module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
    end
  end
end
