defmodule Jidoka.ApprovalPredicate do
  @moduledoc """
  Module contract for dynamic operation approval predicates.

  Approval predicates receive a `Jidoka.Context` and return whether an approval
  policy should apply to the current operation call. They are intentionally
  module-based rather than anonymous functions so agent specs and snapshots stay
  durable.
  """

  @type result :: boolean() | {:ok, boolean()} | {:error, term()}

  @callback call(Jidoka.Context.t()) :: result()

  @doc """
  Defines a reusable approval predicate module.
  """
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(_opts \\ []) do
    quote location: :keep do
      @behaviour Jidoka.ApprovalPredicate
    end
  end

  @doc "Validates that a module implements the approval predicate contract."
  @spec validate_module(module() | nil) :: :ok | {:error, term()}
  def validate_module(nil), do: :ok

  def validate_module(module) when is_atom(module) and not is_nil(module) do
    case Code.ensure_compiled(module) do
      {:module, _module} ->
        if function_exported?(module, :call, 1) do
          :ok
        else
          {:error, {:invalid_approval_predicate_module, module}}
        end

      {:error, reason} ->
        {:error, {:approval_predicate_not_loaded, module, reason}}
    end
  rescue
    exception -> {:error, {:approval_predicate_validation_failed, module, exception}}
  end

  def validate_module(predicate), do: {:error, {:invalid_approval_predicate, predicate}}

  @doc "Evaluates a predicate module against a runtime context."
  @spec evaluate(module() | nil, Jidoka.Context.t()) :: {:ok, boolean()} | {:error, term()}
  def evaluate(nil, %Jidoka.Context{}), do: {:ok, true}

  def evaluate(module, %Jidoka.Context{} = context) when is_atom(module) and not is_nil(module) do
    with :ok <- validate_module(module) do
      module.call(context)
      |> normalize_result(module)
    end
  rescue
    exception -> {:error, {:approval_predicate_failed, module, exception}}
  catch
    kind, reason -> {:error, {:approval_predicate_failed, module, {kind, reason}}}
  end

  def evaluate(predicate, %Jidoka.Context{}), do: {:error, {:invalid_approval_predicate, predicate}}

  defp normalize_result(result, _module) when is_boolean(result), do: {:ok, result}
  defp normalize_result({:ok, result}, _module) when is_boolean(result), do: {:ok, result}
  defp normalize_result({:error, reason}, _module), do: {:error, reason}

  defp normalize_result(result, module),
    do: {:error, {:invalid_approval_predicate_result, module, result}}
end
