defmodule Jidoka.Effect.OperationFailure do
  @moduledoc """
  Provider-neutral classification for operation failures.

  Recoverable failures are safe model observations. Transport failures can be
  retried when the operation idempotency permits it. Policy, review,
  reconciliation, cancellation, and runtime failures stop the turn.
  """

  alias Jidoka.CodingPack.Error, as: CodingError
  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Schema

  @kinds [:recoverable, :transport, :policy, :review, :reconciliation, :cancelled, :runtime]
  @transient_reasons [
    :closed,
    :connection_closed,
    :econnrefused,
    :enetdown,
    :enetunreach,
    :ehostunreach,
    :overloaded,
    :rate_limited,
    :service_unavailable,
    :timeout
  ]
  @cancelled_codes [:coding_mutation_cancelled, :coding_shell_cancelled]
  @policy_codes [
    :coding_path_ignored,
    :coding_shell_network_denied,
    :coding_verify_target_forbidden,
    :coding_verify_target_unsafe
  ]

  @schema Zoi.struct(
            __MODULE__,
            %{
              kind: Schema.atom_enum(@kinds),
              code: Zoi.union([Zoi.atom(), Zoi.string()]),
              message: Zoi.string(),
              reason: Zoi.any(),
              details: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type kind ::
          :recoverable
          | :transport
          | :policy
          | :review
          | :reconciliation
          | :cancelled
          | :runtime

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the operation-failure schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns all stable operation-failure kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Builds an explicitly classified operation failure."
  @spec new(kind(), term(), keyword()) :: t()
  def new(kind, reason, opts \\ []) when kind in @kinds and is_list(opts) do
    Schema.parse!(
      @schema,
      %{
        kind: kind,
        code: Keyword.get(opts, :code, failure_code(reason)),
        message: Keyword.get(opts, :message, failure_message(reason)),
        reason: reason,
        details: opts |> Keyword.get(:details, failure_details(reason)) |> safe_details()
      },
      "operation failure"
    )
  end

  @doc "Marks a failure as a model-recoverable tool result."
  @spec recoverable(term(), keyword()) :: t()
  def recoverable(reason, opts \\ []), do: new(:recoverable, reason, opts)

  @doc "Marks a failure as a retryable transport failure."
  @spec transport(term(), keyword()) :: t()
  def transport(reason, opts \\ []), do: new(:transport, reason, opts)

  @doc "Marks a failure as a policy stop."
  @spec policy(term(), keyword()) :: t()
  def policy(reason, opts \\ []), do: new(:policy, reason, opts)

  @doc "Marks a failure as a review stop."
  @spec review(term(), keyword()) :: t()
  def review(reason, opts \\ []), do: new(:review, reason, opts)

  @doc "Marks a failure as a reconciliation stop."
  @spec reconciliation(term(), keyword()) :: t()
  def reconciliation(reason, opts \\ []), do: new(:reconciliation, reason, opts)

  @doc "Marks a failure as cancellation."
  @spec cancelled(term(), keyword()) :: t()
  def cancelled(reason \\ :cancelled, opts \\ []), do: new(:cancelled, reason, opts)

  @doc "Marks a failure as a runtime stop."
  @spec runtime(term(), keyword()) :: t()
  def runtime(reason, opts \\ []), do: new(:runtime, reason, opts)

  @doc "Classifies a raw operation failure without executing any retry."
  @spec classify(term()) :: t()
  def classify(%__MODULE__{} = failure), do: failure

  def classify(%CodingError{code: code} = error) when code in @cancelled_codes,
    do: cancelled(error)

  def classify(%CodingError{code: code} = error) do
    if policy_code?(code), do: policy(error), else: recoverable(error)
  end

  def classify(%Req.TransportError{} = error), do: transport(error)
  def classify(%{status: status} = error) when status in [408, 409, 425, 429], do: transport(error)
  def classify(%{status: status} = error) when is_integer(status) and status >= 500, do: transport(error)
  def classify(%{reason: reason} = error) when reason in @transient_reasons, do: transport(error)
  def classify({:error, reason}), do: classify(reason)
  def classify(reason) when reason in [:cancelled, :canceled], do: cancelled(reason)

  def classify({reason, _detail} = error) when reason in @transient_reasons,
    do: transport(error)

  def classify(reason) when reason in @transient_reasons, do: transport(reason)
  def classify({:capability_timeout, :operation, _timeout_ms} = error), do: transport(error)
  def classify({:capability_exit, _reason} = error), do: runtime(error)
  def classify({:invalid_capability_result, _result} = error), do: runtime(error)
  def classify({:policy_denied, _rule_id, _reason} = error), do: policy(error)
  def classify({:control_failed, _control, _boundary, _reason} = error), do: policy(error)
  def classify({:control_blocked, _control, _boundary, _reason} = error), do: policy(error)
  def classify({:approval_denied, _response} = error), do: review(error)
  def classify({:approval_expired, _id, _responded_at, _expires_at} = error), do: review(error)
  def classify({:effect_reconciliation_required, _intent} = error), do: reconciliation(error)
  def classify({:unsafe_once_incomplete_effect, _intent} = error), do: reconciliation(error)
  def classify(error) when is_exception(error), do: runtime(error)
  def classify(reason), do: runtime(reason)

  @doc "Returns true when the failure can be sent to the model as a tool result."
  @spec model_visible?(t()) :: boolean()
  def model_visible?(%__MODULE__{kind: :recoverable}), do: true
  def model_visible?(%__MODULE__{}), do: false

  @doc "Returns true when the failure is eligible for a transport retry."
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{kind: :transport}), do: true
  def retryable?(%__MODULE__{}), do: false

  @doc "Projects a failure into safe metadata."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = failure) do
    %{
      kind: failure.kind,
      code: failure.code,
      message: failure.message,
      details: failure.details
    }
  end

  @doc "Projects a recoverable failure into a model-visible tool result."
  @spec to_observation(t()) :: map()
  def to_observation(%__MODULE__{kind: :recoverable} = failure) do
    %{
      "ok" => false,
      "error" => %{
        "kind" => Atom.to_string(failure.kind),
        "code" => to_string(failure.code),
        "message" => failure.message,
        "details" => failure.details
      }
    }
  end

  defp failure_code(%CodingError{code: code}), do: code
  defp failure_code({code, _detail}) when is_atom(code), do: code
  defp failure_code(code) when is_atom(code), do: code
  defp failure_code(_reason), do: :operation_failed

  defp failure_message(%CodingError{code: code}), do: code |> Atom.to_string() |> String.replace("_", " ")
  defp failure_message(reason) when is_atom(reason), do: reason |> Atom.to_string() |> String.replace("_", " ")
  defp failure_message(reason), do: Jidoka.Error.format(reason)

  defp failure_details(%CodingError{details: details}), do: safe_details(details)
  defp failure_details(reason), do: safe_details(%{"reason" => reason})

  defp safe_details(details) do
    projected = Contract.project(details)

    case Contract.validate_portable(projected) do
      :ok -> projected
      {:error, _reason} -> %{"reason" => "non-portable failure details omitted"}
    end
  end

  defp policy_code?(code) do
    code in @policy_codes or String.ends_with?(Atom.to_string(code), "_denied")
  end
end
