defmodule Jidoka.Agent.Spec.Controls.Input do
  @moduledoc """
  Control attached to the input boundary.
  """

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              control: Zoi.atom(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, %__MODULE__{} = input} <- Schema.parse(@schema, attrs),
         :ok <- Jidoka.Control.validate_module(input.control) do
      {:ok, input}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, input} -> input
      {:error, reason} -> raise ArgumentError, "invalid input control: #{inspect(reason)}"
    end
  end

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = input), do: new(input)
  def from_input(input), do: new(input)
end
