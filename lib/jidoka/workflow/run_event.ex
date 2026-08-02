defmodule Jidoka.Workflow.RunEvent do
  @moduledoc "Safe lifecycle projection for one persisted background workflow event."

  @enforce_keys [:run_id, :sequence, :type]
  defstruct [:run_id, :sequence, :type, :component]

  @type t :: %__MODULE__{
          run_id: String.t(),
          sequence: pos_integer(),
          type: String.t(),
          component: atom() | String.t() | nil
        }
end
