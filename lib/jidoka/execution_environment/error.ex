defmodule Jidoka.ExecutionEnvironment.Error do
  @moduledoc "Stable fail-closed error from profile resolution or enforcement validation."

  @enforce_keys [:code, :message]
  defexception [:code, :message, details: %{}]

  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}

  @doc "Builds a typed constrained-execution error."
  @spec new(atom(), String.t(), map()) :: t()
  def new(code, message, details \\ %{}) when is_atom(code) and is_binary(message) and is_map(details) do
    %__MODULE__{code: code, message: message, details: details}
  end

  @doc "Projects the error into portable evidence."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      "code" => Atom.to_string(error.code),
      "message" => error.message,
      "details" => Jidoka.ExecutionEnvironment.Contract.project(error.details)
    }
  end
end
