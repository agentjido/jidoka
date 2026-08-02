defmodule Jidoka.Session.Lease do
  @moduledoc """
  Durable ownership token for one active session continuation.

  A store grants one lease at a time. Every durable checkpoint and final commit
  must present the same lease id. An expired lease can be replaced by recovery.
  """

  alias Jidoka.Id
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              lease_id: Schema.non_empty_string(),
              owner_id: Schema.non_empty_string(),
              request_id: Schema.non_empty_string(),
              acquired_at_ms: Zoi.integer() |> Zoi.gte(0),
              expires_at_ms: Zoi.integer() |> Zoi.gte(0)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a session lease."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a session lease from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds a new lease for one request."
  @spec acquire(String.t(), non_neg_integer(), pos_integer(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def acquire(request_id, now_ms, ttl_ms, opts \\ [])

  def acquire(request_id, now_ms, ttl_ms, opts)
      when is_binary(request_id) and is_integer(now_ms) and is_integer(ttl_ms) and ttl_ms > 0 do
    with {:ok, lease_id} <- Id.generate("lease", Keyword.get(opts, :id_generator)) do
      new(
        lease_id: lease_id,
        owner_id: Keyword.get(opts, :owner_id, default_owner_id()),
        request_id: request_id,
        acquired_at_ms: now_ms,
        expires_at_ms: now_ms + ttl_ms
      )
    end
  end

  def acquire(request_id, now_ms, ttl_ms, _opts),
    do: {:error, {:invalid_session_lease, request_id, now_ms, ttl_ms}}

  @doc "Returns true when the lease has reached its expiry time."
  @spec expired?(t(), non_neg_integer()) :: boolean()
  def expired?(%__MODULE__{expires_at_ms: expires_at_ms}, now_ms) when is_integer(now_ms),
    do: now_ms >= expires_at_ms

  @doc "Extends a lease from the given wall-clock time."
  @spec renew(t(), non_neg_integer(), pos_integer()) :: t()
  def renew(%__MODULE__{} = lease, now_ms, ttl_ms)
      when is_integer(now_ms) and is_integer(ttl_ms) and ttl_ms > 0 do
    %__MODULE__{lease | expires_at_ms: now_ms + ttl_ms}
  end

  defp default_owner_id, do: "#{node()}:#{inspect(self())}"
end
