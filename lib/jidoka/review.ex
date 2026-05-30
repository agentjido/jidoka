defmodule Jidoka.Review do
  @moduledoc """
  Durable human-review data contracts.

  Runtime controls can return interrupts that pause a turn before an unsafe or
  externally reviewed operation executes. Jidoka stores that pause as
  `Jidoka.Review.Interrupt`, exposes it to applications as
  `Jidoka.Review.Request`, and resumes with `Jidoka.Review.Response`.
  """

  @type interrupt :: Jidoka.Review.Interrupt.t()
  @type request :: Jidoka.Review.Request.t()
  @type response :: Jidoka.Review.Response.t()
end
