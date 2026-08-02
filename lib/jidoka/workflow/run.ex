defmodule Jidoka.Workflow.Run do
  @moduledoc "Reconnectable public view of one background workflow run."

  @statuses [:pending, :running, :completed, :failed, :hibernated, :recoverable]
  @enforce_keys [:id, :workflow_id, :status, :outcomes, :event_count]
  defstruct [:id, :workflow_id, :status, :output, :error, :outcomes, :event_count]

  @type status :: :pending | :running | :completed | :failed | :hibernated | :recoverable
  @type t :: %__MODULE__{
          id: String.t(),
          workflow_id: String.t(),
          status: status(),
          output: term(),
          error: term(),
          outcomes: map(),
          event_count: non_neg_integer()
        }

  @doc "Returns the supported background run statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Returns true for a terminal background run."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in [:completed, :failed, :hibernated]
end
