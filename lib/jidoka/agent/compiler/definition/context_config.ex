defmodule Jidoka.Agent.Definition.ContextConfig do
  @moduledoc false

  @spec resolve_schema!(term(), module()) :: term()
  def resolve_schema!(nil, _owner_module), do: nil

  def resolve_schema!(schema, owner_module) do
    case Jidoka.Context.validate_schema(schema) do
      :ok ->
        schema

      {:error, reason} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: context_schema_error(reason),
                path: [:agent, :context],
                value: schema,
                hint: "Use `context Zoi.object(%{...})` inside the agent block.",
                module: owner_module
              )
    end
  end

  @spec resolve_defaults!(module(), term()) :: map()
  def resolve_defaults!(owner_module, schema) do
    case Jidoka.Context.defaults(schema) do
      {:ok, context} ->
        context

      {:error, reason} ->
        raise Jidoka.Agent.Dsl.Error.exception(
                message: context_schema_error(reason),
                path: [:agent, :context],
                hint: "Ensure the context Zoi schema parses an empty input to map defaults.",
                module: owner_module
              )
    end
  end

  defp context_schema_error(%{message: message}) when is_binary(message), do: message
  defp context_schema_error(reason), do: Jidoka.Error.format(reason)
end
