defmodule Jidoka.Session.Sequence.Request do
  @moduledoc """
  Opaque handle for an asynchronous ordered session sequence.

  The handle contains public request identity and controller identity. It does
  not contain a task, a cancellation token, a provider client, or durable
  session state. Use `Jidoka.await/2` and `Jidoka.cancel/2`; do not control the
  controller process directly.
  """

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              request_id: Schema.non_empty_string(),
              controller: Zoi.pid(),
              session_id: Schema.non_empty_string(),
              started_at_ms: Zoi.integer() |> Zoi.gte(0),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true,
            unrecognized_keys: :error
          )

  @opaque t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc false
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Schema.parse!(@schema, attrs, "session sequence request")

  @doc false
  @spec controller(term()) :: {:ok, pid()} | {:error, :invalid_sequence_request}
  def controller(%__MODULE__{controller: controller}), do: {:ok, controller}
  def controller(_request), do: {:error, :invalid_sequence_request}

  @doc false
  @spec request?(term()) :: boolean()
  def request?(%__MODULE__{}), do: true
  def request?(_request), do: false
end
