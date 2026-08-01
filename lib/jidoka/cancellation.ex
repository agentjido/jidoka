defmodule Jidoka.Cancellation do
  @moduledoc """
  Typed evidence that an asynchronous Jidoka request was cancelled.

  Cancellation is request-scoped runtime data. It is not a turn snapshot and it
  does not imply that an external side effect was rolled back.
  """

  alias Jidoka.Context
  alias Jidoka.Schema
  alias __MODULE__.Token

  @schema Zoi.struct(
            __MODULE__,
            %{
              request_id: Schema.non_empty_string(),
              forced?: Zoi.boolean() |> Zoi.default(false),
              cancelled_at_ms: Zoi.integer() |> Zoi.gte(0),
              reason: Schema.atom_enum([:cancelled]) |> Zoi.default(:cancelled)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the schema for typed cancellation evidence."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds typed cancellation evidence."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds typed cancellation evidence or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "cancellation")

  @doc "Returns true when a runtime context or token has a cancellation request."
  @spec requested?(Context.t() | Token.t() | term()) :: boolean()
  def requested?(%Context{} = context) do
    context
    |> Context.get_runtime(:cancellation)
    |> requested?()
  end

  def requested?(%Token{} = token), do: Token.requested?(token)
  def requested?(_value), do: false

  @doc false
  @spec check(keyword() | Token.t() | nil) :: :ok | {:error, :cancelled}
  def check(opts) when is_list(opts) do
    opts
    |> Keyword.get(:cancellation)
    |> check()
  end

  def check(%Token{} = token) do
    if Token.requested?(token), do: {:error, :cancelled}, else: :ok
  end

  def check(nil), do: :ok

  @doc false
  @spec cancelled_reason?(term()) :: boolean()
  def cancelled_reason?(:cancelled), do: true
  def cancelled_reason?({:error, reason}), do: cancelled_reason?(reason)
  def cancelled_reason?(%{details: %{cause: :cancelled}}), do: true
  def cancelled_reason?(%{error: reason}), do: cancelled_reason?(reason)
  def cancelled_reason?(_reason), do: false

  defmodule Token do
    @moduledoc false

    @enforce_keys [:ref, :owner]
    defstruct [:ref, :owner]

    @opaque t :: %__MODULE__{ref: reference(), owner: pid()}

    @spec new() :: t()
    def new do
      %__MODULE__{ref: :atomics.new(1, signed: false), owner: self()}
    end

    @spec request(t()) :: :ok
    def request(%__MODULE__{ref: ref}) do
      :ok = :atomics.put(ref, 1, 1)
    end

    @spec requested?(t()) :: boolean()
    def requested?(%__MODULE__{ref: ref}), do: :atomics.get(ref, 1) == 1

    @spec register(t(), pid()) :: :ok
    def register(%__MODULE__{owner: owner}, pid \\ self()) when is_pid(pid) do
      send(owner, {:jidoka_cancellation_member, pid})
      :ok
    end
  end
end
