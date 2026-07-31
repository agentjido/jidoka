defmodule Jidoka.Agent.Spec.Controls.Output do
  @moduledoc """
  Control attached to the final output boundary.
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

  @doc "Returns the Zoi schema for an output control."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds an output control from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, %__MODULE__{} = output} <- Schema.parse(@schema, attrs),
         :ok <- Jidoka.Control.validate_module(output.control) do
      {:ok, output}
    end
  end

  @doc "Builds an output control and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, output} -> output
      {:error, reason} -> raise ArgumentError, "invalid output control: #{inspect(reason)}"
    end
  end

  @doc "Normalizes an existing output control, keyword list, or map."
  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = output), do: new(output)
  def from_input(input), do: new(input)
end
