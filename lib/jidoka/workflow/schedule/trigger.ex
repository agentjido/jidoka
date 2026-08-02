defmodule Jidoka.Workflow.Schedule.Trigger do
  @moduledoc "Inspectable evidence for one schedule trigger decision."

  @enforce_keys [:schedule_id, :due_at, :triggered_at, :status, :attempts]
  defstruct [:schedule_id, :due_at, :triggered_at, :status, :run_id, :reason, :attempts]

  @type t :: %__MODULE__{
          schedule_id: String.t(),
          due_at: DateTime.t(),
          triggered_at: DateTime.t(),
          status: :started | :skipped | :failed | :cancelled,
          run_id: String.t() | nil,
          reason: term(),
          attempts: pos_integer()
        }
end
