defmodule Jidoka.Chat.Request do
  @moduledoc """
  Opaque handle for an asynchronous Jidoka chat request.

  The handle contains public request identity and controller identity. It does
  not contain a worker task or cancellation token. Use `Jidoka.await/2` and
  `Jidoka.cancel/2` for all lifecycle actions.
  """

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              request_id: Schema.non_empty_string(),
              controller: Zoi.pid(),
              target: Zoi.any(),
              session_id: Zoi.string() |> Zoi.nullish(),
              stream_to: Zoi.pid() |> Zoi.nullish(),
              started_at_ms: Zoi.integer(),
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
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs), do: Schema.parse!(@schema, attrs, "chat request")

  @doc false
  @spec controller(term()) :: {:ok, pid()} | {:error, :invalid_async_request}
  def controller(%__MODULE__{request_id: request_id, controller: controller})
      when is_binary(request_id) and request_id != "" and is_pid(controller),
      do: {:ok, controller}

  def controller(_request), do: {:error, :invalid_async_request}
end
