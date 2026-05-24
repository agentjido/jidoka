defmodule Jidoka.Agent.Definition.OutputConfig do
  @moduledoc false

  @spec resolve!(module(), Jidoka.Agent.Dsl.Result.t() | nil) :: Jidoka.Output.t() | nil
  def resolve!(_owner_module, nil), do: nil

  def resolve!(owner_module, %Jidoka.Agent.Dsl.Result{} = result) do
    schema = result.schema
    retries = result.retries || 1
    mode = result.on_validation_error || :repair

    case Jidoka.Output.new(schema: schema, retries: retries, on_validation_error: mode) do
      {:ok, %Jidoka.Output{schema_kind: :zoi} = output} ->
        output

      {:ok, %Jidoka.Output{schema_kind: :json_schema}} ->
        raise_output_error!(
          owner_module,
          "agent.result must be a Zoi object/map schema in the Elixir DSL.",
          schema,
          "Use `result Zoi.object(%{...})`. JSON Schema maps are only accepted in imported specs.",
          result
        )

      {:error, message} ->
        raise_output_error!(
          owner_module,
          result_error_message(message),
          schema,
          "Use `result Zoi.object(%{...}), repair: 1` with non-negative repair attempts.",
          result
        )
    end
  end

  defp raise_output_error!(owner_module, message, value, hint, result) do
    raise Jidoka.Agent.Dsl.Error.exception(
            message: message,
            path: [:agent, :result],
            value: value,
            hint: hint,
            module: owner_module,
            location: Map.get(result.__spark_metadata__ || %{}, :anno)
          )
  end

  defp result_error_message(message) when is_binary(message) do
    message
    |> String.replace("output schema", "result schema")
    |> String.replace("output retries", "result repair")
    |> String.replace("output on_validation_error", "result on_validation_error")
  end
end
