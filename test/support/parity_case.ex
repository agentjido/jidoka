defmodule Jidoka.ParityCase do
  @moduledoc """
  ExUnit case for opt-in, executable framework parity comparisons.

  Parity tests are excluded from normal test runs and selected by name:

      mix test --only parity:resumable_tool_approval test/parity

  A passing test validates the status declared by its comparison document. A
  partial characterization remains partial even when its parity-tagged test
  passes.
  """

  defmacro __using__(opts) do
    parity = Keyword.fetch!(opts, :parity)

    unless is_atom(parity) do
      raise ArgumentError, "Jidoka.ParityCase expects :parity to be an atom"
    end

    quote do
      use ExUnit.Case, async: false

      @moduletag parity: unquote(parity)
    end
  end
end
