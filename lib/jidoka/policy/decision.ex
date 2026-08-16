defmodule Jidoka.Policy.Decision do
  @moduledoc """
  Portable evidence from the authoritative host policy gate.

  A decision allows, denies, requires consent, marks a request unsupported, or
  pauses one protected operation effect for review. A gate rejects
  `:require_review` for every other effect kind. The rule identifier and
  evidence describe the host rule that made the decision.
  """

  alias Jidoka.Policy.Request
  alias Jidoka.Schema

  @version 1
  @outcomes [:allow, :deny, :consent_required, :unsupported, :require_review]

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.literal(@version) |> Zoi.default(@version),
              outcome: Schema.atom_enum(@outcomes),
              rule_id: Schema.non_empty_string(),
              reason: Zoi.any() |> Zoi.nullish(),
              evidence: Zoi.map() |> Zoi.default(%{}),
              decided_at_ms: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish()
            },
            coerce: true
          )
          |> Zoi.refine({__MODULE__, :validate_portable, []})

  @type outcome :: :allow | :deny | :consent_required | :unsupported | :require_review
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the current policy-decision version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Returns the supported decision outcomes."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc "Returns the Zoi schema for a policy decision."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a policy decision from portable attributes."
  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = decision), do: Schema.parse(@schema, decision)
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds a policy decision and raises for invalid attributes."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "policy decision")

  @doc false
  @spec validate_portable(t(), keyword()) :: :ok | {:error, String.t()}
  def validate_portable(%__MODULE__{reason: reason, evidence: evidence}, opts) do
    %Request{} =
      probe =
      Request.new!(effect_class: :llm, action: "portable-check", request_id: "portable-check")

    Request.validate_portable(
      %Request{probe | resource: %{"reason" => reason, "evidence" => evidence}},
      opts
    )
  end
end
