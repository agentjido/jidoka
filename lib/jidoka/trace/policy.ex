defmodule Jidoka.Trace.Policy do
  @moduledoc """
  Trace projection policy.

  Policies are data. They decide whether trace entries are emitted, how much to
  sample, and which keys should be omitted or redacted before a trace sink sees
  the event data.
  """

  alias Jidoka.Schema

  @default_redact_keys [
    "api_key",
    "authorization",
    "bearer",
    "password",
    "secret",
    "token"
  ]
  @default_omit_keys [
    "messages",
    "prompt",
    "raw_response",
    "request_body",
    "response_body"
  ]

  @schema Zoi.struct(
            __MODULE__,
            %{
              enabled: Zoi.boolean() |> Zoi.default(true),
              sample_rate: Zoi.number() |> Zoi.gte(0.0) |> Zoi.lte(1.0) |> Zoi.default(1.0),
              redact_keys: Zoi.array(Zoi.string(coerce: true)) |> Zoi.default(@default_redact_keys),
              omit_keys: Zoi.array(Zoi.string(coerce: true)) |> Zoi.default(@default_omit_keys),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec default_redact_keys() :: [String.t()]
  def default_redact_keys, do: @default_redact_keys

  @spec default_omit_keys() :: [String.t()]
  def default_omit_keys, do: @default_omit_keys

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ []), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ []), do: Schema.parse!(@schema, attrs, "trace policy")

  @spec from_input(t() | keyword() | map() | nil) :: {:ok, t()} | {:error, term()}
  def from_input(nil), do: new()
  def from_input(%__MODULE__{} = policy), do: new(policy)
  def from_input(input), do: new(input)
end
