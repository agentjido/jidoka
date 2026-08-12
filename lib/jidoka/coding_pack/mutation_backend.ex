defmodule Jidoka.CodingPack.MutationBackend do
  @moduledoc "Port implemented by a constrained environment that can mutate workspace files."

  alias Jidoka.CodingPack.Workspace
  alias Jidoka.ExecutionEnvironment.{Checkpoint, EnforcementEvidence}

  @type opts :: keyword()
  @type file_state :: %{
          required(:exists?) => boolean(),
          optional(:content) => String.t() | nil,
          optional(:sha256) => String.t() | nil,
          optional(:size) => non_neg_integer() | nil
        }

  @callback checkpoint(Workspace.t(), opts()) ::
              {:ok, Checkpoint.t() | map(), EnforcementEvidence.t() | map()} | {:error, term()}
  @callback inspect_file(Workspace.t(), String.t(), opts()) ::
              {:ok, file_state() | map(), EnforcementEvidence.t() | map()} | {:error, term()}
  @callback replace_file(Workspace.t(), String.t(), String.t(), opts()) ::
              {:ok, map(), EnforcementEvidence.t() | map()}
              | {:error, term()}
              | {:error, term(), map(), EnforcementEvidence.t() | map()}
  @callback restore(Workspace.t(), Checkpoint.t(), opts()) ::
              {:ok, EnforcementEvidence.t() | map()} | {:error, term()}
end
