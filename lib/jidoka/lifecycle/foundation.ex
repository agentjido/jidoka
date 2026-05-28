defmodule Jidoka.Lifecycle.Foundation do
  @moduledoc false

  alias Jidoka.Lifecycle.PhaseSpec

  @type before_fun :: (Jido.Agent.t(), term() -> {:ok, Jido.Agent.t(), term()} | term())
  @type after_fun :: (Jido.Agent.t(), term(), [term()] -> {:ok, Jido.Agent.t(), [term()]} | term())

  @spec before_phase_specs(before_fun()) :: [PhaseSpec.t()]
  def before_phase_specs(super_fun) when is_function(super_fun, 2) do
    [
      PhaseSpec.before(:jido_ai_before, :jido_ai, super_fun)
    ]
  end

  @spec after_phase_specs(after_fun()) :: [PhaseSpec.t()]
  def after_phase_specs(super_fun) when is_function(super_fun, 3) do
    [
      PhaseSpec.after_phase(:jido_ai_after, :jido_ai, super_fun)
    ]
  end
end
