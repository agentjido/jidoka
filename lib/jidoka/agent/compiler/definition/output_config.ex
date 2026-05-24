defmodule Jidoka.Agent.Definition.OutputConfig do
  @moduledoc false

  @spec resolve!(module(), Jidoka.Agent.Dsl.Output.t() | nil) :: Jidoka.Output.t() | nil
  def resolve!(_owner_module, nil), do: nil

  def resolve!(owner_module, %Jidoka.Agent.Dsl.Output{} = output) do
    schema = output.schema
    retries = output.retries || 1
    mode = output.on_validation_error || :repair

    case Jidoka.Output.new(schema: schema, retries: retries, on_validation_error: mode) do
      {:ok, %Jidoka.Output{schema_kind: :zoi} = output} ->
        output

      {:ok, %Jidoka.Output{schema_kind: :json_schema}} ->
        raise_output_error!(
          owner_module,
          "agent.output.schema must be a Zoi object/map schema in the Elixir DSL.",
          schema,
          "Use `schema Zoi.object(%{...})`. JSON Schema maps are only accepted in imported specs.",
          output
        )

      {:error, message} ->
        raise_output_error!(
          owner_module,
          message,
          schema,
          "Use `output do schema Zoi.object(%{...}) end` with non-negative retries and :repair or :error mode.",
          output
        )
    end
  end

  defp raise_output_error!(owner_module, message, value, hint, output) do
    raise Jidoka.Agent.Dsl.Error.exception(
            message: message,
            path: [:agent, :output],
            value: value,
            hint: hint,
            module: owner_module,
            location: Map.get(output.__spark_metadata__ || %{}, :anno)
          )
  end
end
