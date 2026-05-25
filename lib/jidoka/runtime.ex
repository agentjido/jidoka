defmodule Jidoka.Runtime do
  @moduledoc """
  Default Jido runtime instance for Jidoka agents.

  Generated Jidoka agents use this shared runtime when you call their
  `start_link/1` helper, `Jidoka.start_agent/2`, or `Jidoka.chat/3` with a
  compiled agent module target.

  There are three common ownership shapes:

  - supervise the generated agent directly when it is an application service
  - use `Jidoka.Session` when a conversation should start or reuse a
    session-scoped runtime agent
  - define an app-owned Jido instance when you need runtime-scoped registries,
    storage, persistence, worker pools, or deployment boundaries

  If your application needs an OTP instance scoped runtime, define your own Jido
  instance in the host app and start the generated Jidoka runtime module there:

      defmodule MyApp.AgentRuntime do
        use Jido, otp_app: :my_app
      end

      # in your application supervision tree
      children = [MyApp.AgentRuntime]

      {:ok, pid} =
        MyApp.AgentRuntime.start_agent(
          MyApp.SupportAgent.runtime_module(),
          id: "support-router"
        )

      {:ok, reply} = Jidoka.chat(pid, "Triage this ticket.")

  This keeps Jidoka as the authoring onramp while letting advanced applications
  use Jido's instance-level registry, task supervisor, agent supervisor,
  scheduler, debug configuration, worker pools, partitions, and persistence
  primitives directly.

  In the default runtime, Jidoka owns session addressing, runtime context,
  request inspection, trace projection, and compaction snapshots. Applications
  that need durable restore, checkpointing, journals, or storage adapters should
  move the generated runtime module into an app-owned runtime boundary.
  """

  use Jido, otp_app: :jidoka
end
