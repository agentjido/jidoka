defmodule Jido.MCP.Endpoint do
  @moduledoc false

  defstruct [:id, :transport, :client_info, :protocol_version, :capabilities, :timeouts]

  def new(id, attrs) do
    {:ok, struct(__MODULE__, Map.put(attrs, :id, id))}
  end
end
