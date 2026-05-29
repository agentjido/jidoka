defmodule Jidoka.Runtime.JidoActions do
  @moduledoc """
  Runtime support for executing Jido actions as Jidoka operations.

  Jido actions are the canonical tool implementation for Jidoka. This module
  converts action modules into `Agent.Spec.Operation` data and builds the
  operation function used by the effect interpreter.
  """

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Schema

  @type action_module :: module()

  @doc """
  Converts Jido action modules into Jidoka operation specs.
  """
  @spec operations_from_actions([action_module()]) :: [Operation.t()]
  def operations_from_actions(actions) when is_list(actions) do
    Enum.map(actions, &operation_from_action!/1)
  end

  @doc """
  Converts a single Jido action module into a Jidoka operation spec.
  """
  @spec operation_from_action!(action_module()) :: Operation.t()
  def operation_from_action!(action) when is_atom(action) do
    tool = action.to_tool()

    Operation.new!(
      name: tool.name,
      description: tool.description,
      idempotency: :idempotent,
      metadata: %{
        "runtime" => "jido_action",
        "action" => inspect(action),
        "parameters_schema" => tool.parameters_schema
      }
    )
  end

  @doc """
  Builds a Jidoka operation function backed by Jido actions.
  """
  @spec operations([action_module()], keyword()) ::
          Jidoka.Runtime.Capabilities.operation_capability()
  def operations(actions, opts \\ []) when is_list(actions) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    tools =
      Map.new(actions, fn action ->
        tool = action.to_tool()
        {tool.name, tool}
      end)

    fn
      %Effect.Intent{kind: :operation, payload: payload}, %Effect.Journal{} ->
        with {:ok, name} <- Schema.fetch_key(payload, :name),
             {:ok, tool} <- fetch_tool(tools, name) do
          arguments = Schema.get_key(payload, :arguments, %{})
          call_tool(tool, arguments, context)
        end

      %Effect.Intent{kind: kind}, _journal ->
        {:error, {:unsupported_effect_kind, kind}}
    end
  end

  defp fetch_tool(tools, name) do
    case Map.fetch(tools, to_string(name)) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, {:missing_jido_action, name}}
    end
  end

  defp call_tool(%{function: function}, arguments, context) when is_function(function, 2) do
    case function.(arguments, context) do
      {:ok, encoded} -> {:ok, decode_tool_payload(encoded)}
      {:error, encoded} -> {:error, decode_tool_payload(encoded)}
    end
  end

  defp decode_tool_payload(encoded) when is_binary(encoded) do
    case Jason.decode(encoded) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> encoded
    end
  end

  defp decode_tool_payload(value), do: value
end
