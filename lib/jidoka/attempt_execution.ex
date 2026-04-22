defmodule Jidoka.AttemptExecution do
  @moduledoc """
  Execution boundary between orchestration and runtime adapters.

  The boundary defines a typed contract (`AttemptSpec` and `AttemptOutput`)
  for a concrete execution adapter and a single execution entrypoint.
  """

  alias Jidoka.EnvironmentLease
  alias Jidoka.SessionServer

  defmodule AttemptSpec do
    @moduledoc """
    Typed execution input passed to an adapter.
    """
    alias Jidoka.EnvironmentLease

    @enforce_keys [:session_id, :run_id, :attempt_id, :task, :attempt_number, :environment_lease]
    defstruct [
      :session_id,
      :run_id,
      :attempt_id,
      :task,
      :attempt_number,
      :environment_lease,
      :task_pack,
      :metadata,
      :adapter,
      :verification_adapter
    ]

    @type t :: %__MODULE__{
            session_id: String.t(),
            run_id: String.t(),
            attempt_id: String.t(),
            task: String.t(),
            attempt_number: pos_integer(),
            environment_lease: EnvironmentLease.t(),
            task_pack: atom() | String.t(),
            metadata: map(),
            adapter: module(),
            verification_adapter: module() | nil
          }
  end

  defmodule ProgressEvent do
    @moduledoc """
    Typed execution progress record emitted by adapters.
    """
    @enforce_keys [:label]
    defstruct [:label, :message, :metadata]

    @type t :: %__MODULE__{
            label: atom(),
            message: String.t() | nil,
            metadata: map()
          }
  end

  defmodule AttemptOutput do
    @moduledoc """
    Typed execution result returned by adapters.
    """
    @type status :: :succeeded | :retryable_failed | :terminal_failed

    @enforce_keys [:status]
    defstruct [
      :status,
      progress: [],
      metadata: %{},
      artifacts: [],
      error: nil
    ]

    @type t :: %__MODULE__{
            status: status(),
            progress: [ProgressEvent.t()],
            metadata: map(),
            artifacts: [String.t() | map()],
            error: term()
          }
  end

  @callback execute(AttemptSpec.t()) :: {:ok, AttemptOutput.t()} | {:error, term()}

  @doc """
  Emit a live progress event for an in-flight attempt.
  """
  @spec report_progress(AttemptSpec.t(), ProgressEvent.t()) :: :ok | {:error, term()}
  def report_progress(%AttemptSpec{attempt_id: attempt_id}, %ProgressEvent{} = progress) do
    SessionServer.mark_attempt_progress(attempt_id, %{
      label: progress.label,
      message: progress.message,
      metadata: progress.metadata
    })
  end

  @spec report_progress(AttemptSpec.t(), atom(), String.t() | nil, map()) ::
          :ok | {:error, term()}
  def report_progress(%AttemptSpec{} = spec, label, message \\ nil, metadata \\ %{})
      when is_atom(label) and is_map(metadata) do
    report_progress(spec, %ProgressEvent{label: label, message: message, metadata: metadata})
  end

  @doc """
  Execute the typed attempt spec using the configured adapter.
  """
  @spec execute(AttemptSpec.t()) :: {:ok, AttemptOutput.t()} | {:error, term()}
  def execute(%AttemptSpec{adapter: nil} = spec),
    do: __MODULE__.NoopAdapter.execute(%{spec | adapter: __MODULE__.NoopAdapter})

  def execute(%AttemptSpec{} = spec),
    do: spec.adapter.execute(spec)
end
