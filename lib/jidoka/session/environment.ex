defmodule Jidoka.Session.Environment do
  @moduledoc """
  Portable execution-environment state for a durable session.

  This value can contain a profile request, a durable binding, an immutable
  checkpoint, and confirmed enforcement evidence. It cannot contain a manager
  process, an adapter client, or an acquired runtime handle.
  """

  alias Jidoka.ExecutionEnvironment.Binding
  alias Jidoka.ExecutionEnvironment.Checkpoint
  alias Jidoka.ExecutionEnvironment.EnforcementEvidence
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.Schema

  @version 1
  @statuses [:opened, :available, :checkpointed, :restored, :forked, :cleaned]
  @retentions [:ephemeral, :durable]

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.literal(@version) |> Zoi.default(@version),
              status: Schema.atom_enum(@statuses),
              retention: Schema.atom_enum(@retentions) |> Zoi.default(:ephemeral),
              request: Zoi.lazy({PolicyRequest, :schema, []}),
              binding: Zoi.lazy({Binding, :schema, []}),
              checkpoint: Zoi.lazy({Checkpoint, :schema, []}) |> Zoi.nullish(),
              evidence: Zoi.lazy({EnforcementEvidence, :schema, []})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the portable session-environment schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds portable session-environment state."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, %__MODULE__{} = environment} <- Schema.parse(@schema, attrs),
         :ok <- validate_links(environment) do
      {:ok, environment}
    end
  end

  @doc "Builds portable session-environment state and raises for invalid input."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, environment} -> environment
      {:error, reason} -> raise ArgumentError, "invalid session environment: #{inspect(reason)}"
    end
  end

  @doc "Records a newly opened durable binding."
  @spec opened(PolicyRequest.t(), Binding.t(), EnforcementEvidence.t(), :ephemeral | :durable) :: t()
  def opened(%PolicyRequest{} = request, %Binding{} = binding, %EnforcementEvidence{} = evidence, retention) do
    new!(status: :opened, request: request, binding: binding, evidence: evidence, retention: retention)
  end

  @doc "Records a confirmed lifecycle observation without changing the binding."
  @spec observed(t(), EnforcementEvidence.t(), atom()) :: t()
  def observed(%__MODULE__{} = environment, %EnforcementEvidence{} = evidence, status \\ :available) do
    new!(%__MODULE__{environment | status: status, evidence: evidence})
  end

  @doc "Records a new binding and immutable checkpoint."
  @spec checkpointed(t(), Binding.t(), Checkpoint.t(), EnforcementEvidence.t()) :: t()
  def checkpointed(
        %__MODULE__{} = environment,
        %Binding{} = binding,
        %Checkpoint{} = checkpoint,
        %EnforcementEvidence{} = evidence
      ) do
    new!(%__MODULE__{
      environment
      | status: :checkpointed,
        binding: binding,
        checkpoint: checkpoint,
        evidence: evidence
    })
  end

  @doc "Records a restored binding."
  @spec restored(t(), Binding.t(), EnforcementEvidence.t()) :: t()
  def restored(%__MODULE__{} = environment, %Binding{} = binding, %EnforcementEvidence{} = evidence) do
    new!(%__MODULE__{
      environment
      | status: :restored,
        binding: binding,
        checkpoint: nil,
        evidence: evidence
    })
  end

  @doc "Builds state for an environment fork."
  @spec forked(t(), Binding.t(), Checkpoint.t(), EnforcementEvidence.t()) :: t()
  def forked(
        %__MODULE__{} = source,
        %Binding{} = binding,
        %Checkpoint{} = checkpoint,
        %EnforcementEvidence{} = evidence
      ) do
    new!(%__MODULE__{
      source
      | status: :forked,
        binding: binding,
        checkpoint: checkpoint,
        evidence: evidence
    })
  end

  @doc "Marks durable environment resources as cleaned."
  @spec cleaned(t(), EnforcementEvidence.t()) :: t()
  def cleaned(%__MODULE__{} = environment, %EnforcementEvidence{} = evidence) do
    new!(%__MODULE__{environment | status: :cleaned, evidence: evidence})
  end

  @doc "Returns an error when cleaned state is used again."
  @spec ensure_usable(t()) :: :ok | {:error, term()}
  def ensure_usable(%__MODULE__{status: :cleaned, binding: binding}),
    do: {:error, {:execution_environment_cleaned, binding.resource_ref}}

  def ensure_usable(%__MODULE__{}), do: :ok

  defp validate_links(%__MODULE__{request: request, binding: binding, checkpoint: checkpoint}) do
    case same_profile(request, binding) do
      :ok -> checkpoint_matches(binding, checkpoint)
      {:error, _reason} = error -> error
    end
  end

  defp same_profile(%PolicyRequest{profile_id: profile_id}, %Binding{profile_id: profile_id}), do: :ok

  defp same_profile(%PolicyRequest{} = request, %Binding{} = binding),
    do: {:error, {:execution_environment_profile_mismatch, request.profile_id, binding.profile_id}}

  defp checkpoint_matches(_binding, nil), do: :ok

  defp checkpoint_matches(
         %Binding{profile_digest: digest, revision: revision},
         %Checkpoint{profile_digest: digest, binding_revision: revision}
       ),
       do: :ok

  defp checkpoint_matches(%Binding{} = binding, %Checkpoint{} = checkpoint) do
    {:error, {:execution_environment_checkpoint_mismatch, binding.revision, checkpoint.binding_revision}}
  end
end
