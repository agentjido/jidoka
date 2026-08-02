defmodule Jidoka.Workflow.Loop.Result do
  @moduledoc "Final value and inspectable history from a bounded workflow loop."

  alias Jidoka.Workflow.Loop.{Cursor, Iteration}

  @enforce_keys [:value, :iterations, :created_work]
  defstruct [:value, :iterations, :created_work]

  @type t :: %__MODULE__{
          value: term(),
          iterations: [Iteration.t()],
          created_work: [term()]
        }

  @doc false
  @spec from_cursor(Cursor.t(), term()) :: t()
  def from_cursor(%Cursor{} = cursor, value) do
    %__MODULE__{
      value: value,
      iterations: cursor.iterations,
      created_work: Enum.flat_map(cursor.iterations, & &1.created_work)
    }
  end
end
