defmodule Jidoka.Jido do
  @moduledoc """
  Default Jido runtime instance for Jidoka agents.

  This supervisor owns the Jido process substrate that Jidoka uses by default:
  registry, task supervisor, runtime store, and dynamic agent supervisor.
  """

  use Jido, otp_app: :jidoka
end
