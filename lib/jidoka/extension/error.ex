defmodule Jidoka.Extension.Error do
  @moduledoc "Stable fail-closed extension resolution error."

  @enforce_keys [:code, :message]
  defexception [:code, :message, details: %{}]

  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}

  @doc "Builds an extension error."
  @spec new(atom(), map()) :: t()
  def new(code, details \\ %{}) when is_atom(code) and is_map(details) do
    %__MODULE__{code: code, message: "extension resolution failed", details: details}
  end

  @doc "Projects the error as portable data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      "code" => Atom.to_string(error.code),
      "message" => error.message,
      "details" => Jidoka.ExecutionEnvironment.Contract.project(error.details)
    }
  end
end
