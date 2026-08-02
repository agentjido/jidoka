defmodule Jidoka.Workflow.Loop.Cursor do
  @moduledoc "Serializable continuation data for a suspended bounded loop."

  alias Jidoka.Workflow.Loop.Iteration

  @enforce_keys [:step, :state, :next_iteration, :max_iterations, :iterations]
  defstruct [:step, :state, :next_iteration, :max_iterations, :iterations]

  @type t :: %__MODULE__{
          step: atom(),
          state: term(),
          next_iteration: non_neg_integer(),
          max_iterations: pos_integer(),
          iterations: [Iteration.t()]
        }

  @doc false
  @spec new!(atom(), term(), pos_integer()) :: t()
  def new!(step, state, max_iterations) do
    %__MODULE__{
      step: step,
      state: state,
      next_iteration: 0,
      max_iterations: max_iterations,
      iterations: []
    }
  end

  @doc false
  @spec advance(t(), term(), Iteration.t()) :: t()
  def advance(%__MODULE__{} = cursor, state, %Iteration{} = iteration) do
    %__MODULE__{
      cursor
      | state: state,
        next_iteration: cursor.next_iteration + 1,
        iterations: cursor.iterations ++ [iteration]
    }
  end
end
