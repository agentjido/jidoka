defmodule Jidoka.Workflow.Loop.Iteration do
  @moduledoc "Inspectable data for one bounded loop iteration."

  @enforce_keys [:index, :state, :decision, :output, :created_work]
  defstruct [:index, :state, :decision, :output, :created_work]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          state: term(),
          decision: :cont | :halt | :suspend,
          output: term(),
          created_work: [term()]
        }
end
