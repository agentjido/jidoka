defmodule Jidoka.Chat.Request do
  @moduledoc """
  Data handle for an asynchronous Jidoka chat request.

  The handle is intentionally not part of the durable agent data contract. It is
  caller-owned data for UI processes that stream request-scoped events and await
  the normalized final chat result. `Jidoka.Chat.Async` owns task control.
  """

  alias Jidoka.Cancellation
  alias Jidoka.Cancellation.Token
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              request_id: Zoi.string(),
              task: Schema.typed_struct(Task, quote(do: Task.t())),
              controller: Zoi.pid() |> Zoi.nullish(),
              cancellation: Schema.typed_struct(Token, quote(do: Cancellation.token())) |> Zoi.nullish(),
              target: Zoi.any(),
              session_id: Zoi.string() |> Zoi.nullish(),
              stream_to: Zoi.pid() |> Zoi.nullish(),
              started_at_ms: Zoi.integer(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true,
            unrecognized_keys: :error
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc false
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs), do: Schema.parse!(@schema, attrs, "chat request")
end
