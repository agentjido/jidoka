defmodule Jidoka.Runtime.Controls.Decision do
  @moduledoc false

  @allow_decisions [:allow, :cont, :ok]

  @type t ::
          :allow
          | {:block, term()}
          | {:interrupt, term()}
          | {:error, term()}
          | {:invalid, term()}

  @spec normalize(term()) :: t()
  def normalize(decision) when decision in @allow_decisions, do: :allow
  def normalize({:block, reason}), do: {:block, reason}
  def normalize({:interrupt, reason}), do: {:interrupt, reason}
  def normalize({:error, reason}), do: {:error, reason}
  def normalize(decision), do: {:invalid, decision}
end
