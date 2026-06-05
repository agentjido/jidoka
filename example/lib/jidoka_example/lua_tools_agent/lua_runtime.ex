defmodule JidokaExample.LuaToolsAgent.LuaRuntime do
  @moduledoc false

  alias JidokaExample.LuaToolsAgent.Catalog

  @spec execute(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(script, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:catalog, Catalog.catalog())
      |> Keyword.put_new(:require_read_only?, true)

    Jidoka.Workflow.Lua.execute(script, opts)
  end
end
