defmodule Jidoka.ExecutionEnvironment.Conformance do
  @moduledoc "Reusable structural checks for execution-environment adapters."

  @callbacks [open: 3, acquire: 2, checkpoint: 3, restore: 3, fork: 3, close: 2, cleanup: 2]

  @doc "Checks that an adapter exports the full lifecycle port."
  @spec validate(module()) :: :ok | {:error, {:missing_adapter_callbacks, [{atom(), arity()}]}}
  def validate(adapter) when is_atom(adapter) do
    case Code.ensure_loaded(adapter) do
      {:module, ^adapter} ->
        missing = Enum.reject(@callbacks, fn {name, arity} -> function_exported?(adapter, name, arity) end)
        if missing == [], do: :ok, else: {:error, {:missing_adapter_callbacks, missing}}

      {:error, _reason} ->
        {:error, {:missing_adapter_callbacks, @callbacks}}
    end
  end
end
