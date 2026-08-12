defmodule Jidoka.ExecutionEnvironment.Adapter do
  @moduledoc """
  Provider-neutral lifecycle port for constrained execution adapters.

  Runtime handles are transient adapter values. Bindings, checkpoints, and
  evidence must use Jidoka's portable public contracts.
  """

  alias Jidoka.ExecutionEnvironment.Binding
  alias Jidoka.ExecutionEnvironment.Checkpoint
  alias Jidoka.ExecutionEnvironment.EnforcementEvidence
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.SecurityProfile

  @type handle :: term()

  @callback open(SecurityProfile.t(), PolicyRequest.t(), keyword()) ::
              {:ok, Binding.t() | map(), EnforcementEvidence.t() | map()} | {:error, term()}
  @callback acquire(Binding.t(), keyword()) ::
              {:ok, handle(), EnforcementEvidence.t() | map()} | {:error, term()}
  @callback checkpoint(handle(), Binding.t(), keyword()) ::
              {:ok, Binding.t() | map(), Checkpoint.t() | map(), EnforcementEvidence.t() | map()}
              | {:error, term()}
  @callback restore(Binding.t(), Checkpoint.t(), keyword()) ::
              {:ok, Binding.t() | map(), EnforcementEvidence.t() | map()} | {:error, term()}
  @callback fork(Binding.t(), Checkpoint.t(), keyword()) ::
              {:ok, Binding.t() | map(), Checkpoint.t() | map(), EnforcementEvidence.t() | map()}
              | {:error, term()}
  @callback close(handle(), keyword()) :: {:ok, EnforcementEvidence.t() | map()} | {:error, term()}
  @callback cleanup(Binding.t(), keyword()) :: {:ok, EnforcementEvidence.t() | map()} | {:error, term()}
end
