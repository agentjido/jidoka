defmodule Jidoka.Operation.Registry.Capability do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Operation.Registry

  @doc "Wraps static and extension capabilities with registry lookup and validation."
  @spec wrap(Registry.t(), Jidoka.Operation.Capability.t(), Jidoka.Operation.Capability.t() | nil) ::
          Jidoka.Operation.Capability.t()
  def wrap(%Registry{} = registry, static_capability, extension_capability \\ nil)
      when is_function(static_capability, 3) do
    fn
      %Effect.Intent{kind: :operation, payload: payload} = intent,
      %Effect.Journal{} = journal,
      %Jidoka.Context{} = context ->
        with {:ok, %Effect.OperationRequest{} = request} <-
               Effect.OperationRequest.from_input(payload),
             {:ok, arguments} <- Registry.validate_arguments(registry, request.name, request.arguments),
             {:ok, capability} <- select_capability(registry, request.name, static_capability, extension_capability) do
          request = %Effect.OperationRequest{request | arguments: arguments}
          capability.(%Effect.Intent{intent | payload: Effect.OperationRequest.to_payload(request)}, journal, context)
        end

      %Effect.Intent{kind: kind}, _journal, %Jidoka.Context{} ->
        {:error, {:unsupported_effect_kind, kind}}
    end
  end

  defp select_capability(%Registry{} = registry, name, static, extension)
       when is_function(extension, 3) do
    if Registry.extension?(registry, name), do: {:ok, extension}, else: {:ok, static}
  end

  defp select_capability(%Registry{} = registry, name, static, nil) do
    if Registry.extension?(registry, name),
      do: {:error, {:missing_extension_operation_capability, name}},
      else: {:ok, static}
  end
end
