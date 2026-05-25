defmodule JidokaTest.ErrorFormatTest do
  use ExUnit.Case, async: true

  test "formats invalid context type errors" do
    error = Jidoka.Error.invalid_context(:expected_map, value: [1, 2])

    assert %Jidoka.Error.ValidationError{field: :context, value: [1, 2]} = error

    assert Jidoka.format_error(error) ==
             "Invalid context: pass `context:` as a map or keyword list."
  end

  test "formats schema errors in stable sorted order" do
    error =
      Jidoka.Error.invalid_context(
        {:schema,
         %{
           tenant: ["invalid type: expected string"],
           account_id: ["is required"]
         }},
        value: %{tenant: 123}
      )

    assert %Jidoka.Error.ValidationError{details: %{reason: :schema}} = error

    assert Jidoka.format_error(error) ==
             "Invalid context:\n- account_id: is required\n- tenant: invalid type: expected string"
  end

  test "formats invalid public tool_context option" do
    error = Jidoka.Error.invalid_option(:tool_context, :use_context, value: %{tenant: "acme"})

    assert %Jidoka.Error.ValidationError{field: :tool_context} = error

    assert Jidoka.format_error(error) ==
             "Invalid option: use `context:` for request-scoped data; `tool_context:` is internal."
  end

  test "formats missing context and domain mismatch errors" do
    assert Jidoka.format_error(Jidoka.Error.missing_context(:actor)) ==
             "Missing required context key `actor`. Pass it with `context: %{actor: ...}`."

    assert Jidoka.format_error(Jidoka.Error.invalid_context({:domain_mismatch, MyApp.Domain, Other.Domain})) ==
             "Invalid context: expected `domain` to be MyApp.Domain, got Other.Domain."
  end

  test "builds configuration, execution, and context schema errors" do
    assert %Jidoka.Error.ConfigError{field: :schema, details: %{reason: :expected_zoi_schema}} =
             Jidoka.Error.invalid_context_schema(:expected_zoi_schema, value: :bad)

    assert %Jidoka.Error.ConfigError{field: :schema, details: %{reason: :expected_zoi_map_schema}} =
             Jidoka.Error.invalid_context_schema(:expected_zoi_map_schema, value: :bad)

    assert %Jidoka.Error.ConfigError{field: :schema, details: %{reason: :expected_map_result}} =
             Jidoka.Error.invalid_context_schema({:expected_map_result, [:bad]}, value: :schema)

    assert %Jidoka.Error.ValidationError{field: :context, details: %{reason: :schema_result}} =
             Jidoka.Error.invalid_context({:schema_result, :expected_map, [:bad]}, value: %{tenant: "acme"})

    assert %Jidoka.Error.ConfigError{message: "Bad config.", details: %{code: :bad}} =
             Jidoka.Error.config_error("Bad config.", %{details: %{code: :bad}})

    assert %Jidoka.Error.ExecutionError{message: "Bad run.", phase: :unit} =
             Jidoka.Error.execution_error("Bad run.", phase: :unit)
  end

  test "falls back to inspect for unknown errors" do
    assert Jidoka.format_error(Jidoka.Error.Internal.UnknownError.exception(error: nil)) == "Unknown Jidoka error"
    assert Jidoka.format_error(Jidoka.Error.Internal.UnknownError.exception(error: :boom)) == ":boom"
    assert Jidoka.format_error({:unhandled, :shape}) == "{:unhandled, :shape}"
  end

  test "redacts unknown error payloads before formatting" do
    formatted =
      Jidoka.format_error(
        {:provider_error,
         %{
           raw_response: "raw provider body",
           api_key: "sk-ant-secret1234567890",
           reason: "token=sk-ant-reason1234567890"
         }}
      )

    assert formatted =~ ~s(raw_response: "[OMITTED]")
    assert formatted =~ ~s(api_key: "[REDACTED]")
    assert formatted =~ "token=[REDACTED]"
    refute formatted =~ "raw provider body"
    refute formatted =~ "sk-ant-secret"
    refute formatted =~ "sk-ant-reason"
  end

  test "formats Splode error classes in stable order" do
    error =
      Jidoka.Error.to_class([
        Jidoka.Error.execution_error("Workflow step failed."),
        Jidoka.Error.validation_error("Input is invalid.")
      ])

    assert Jidoka.format_error(error) ==
             "Multiple Jidoka errors:\n- Input is invalid.\n- Workflow step failed."
  end

  test "formats nested Splode error classes" do
    nested =
      Jidoka.Error.to_class([
        Jidoka.Error.to_class([
          Jidoka.Error.validation_error("Nested input.")
        ])
      ])

    assert Jidoka.format_error(nested) == "Nested input."
  end
end
