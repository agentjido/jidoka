defmodule Jidoka.Agent do
  @moduledoc """
  Thin Spark-backed wrapper around `Jido.AI.Agent` for Jidoka.

  This first DSL is intentionally tiny:

      defmodule MyApp.ChatAgent do
        use Jidoka.Agent

        agent :chat_agent do
          model :fast
          instructions "You are a concise assistant."
          context Zoi.object(%{tenant: Zoi.string() |> Zoi.optional()})
        end

        tools do
          action MyApp.Tools.AddNumbers
        end

        capabilities do
          ash_resource MyApp.Accounts.User
        end
      end

  Supported fields are intentionally limited:

  - `agent :id`
  - `agent.context` as an optional Zoi map/object schema for runtime context
  - `agent.model`
  - `agent.instructions` as a string, module callback, or MFA tuple
  - `agent.character` as an optional prompt/persona source
  - `tools` for deterministic action modules
  - `capabilities` for Ash resources, MCP tools, skills, plugins, subagents, and workflows
  - `controls` for input, operation, and result policy
  - `lifecycle` for runtime behavior such as memory, hooks, and compaction
  - `schedules` for first-class recurring agent turns registered by the application

  Vocabulary:

  - context is caller-provided data for a turn
  - agent state belongs to the running process
  - memory recalls facts across turns or from a store
  - compaction summarizes older transcript context for future model calls
  - result is the final app-facing value returned from a turn

  A nested runtime module is generated automatically and uses `Jido.AI.Agent`
  with the configured action modules. The `tools` block supports explicit
  `Jidoka.Action` modules, while `capabilities` handles integrations such as
  `ash_resource` expansion via `AshJido`.
  Subagent entries compile specialist agents into provider-visible delegation
  capabilities while keeping the parent agent in control. Subagent entries can
  tune child `timeout`, public `forward_context`, and parent-visible `result`
  shape without introducing handoffs or workflow graphs.
  Workflow entries compile deterministic `Jidoka.Workflow` modules into
  provider-visible capabilities while keeping ordered business processes in the
  workflow runtime.
  Character entries render structured persona data into the effective system
  prompt before `instructions`; per-request `character:` overrides can be
  supplied through `Jidoka.chat/3` or the generated agent `chat/3` function.
  Plugin entries accept `Jidoka.Plugin` modules and merge their declared
  action-backed operations into the same provider-visible operation surface.
  Schedule entries compile into `schedules/0` metadata that can be registered
  with `Jidoka.Schedule.Manager` from the application runtime boundary.
  """

  @doc false
  @spec prepare_chat_opts(keyword(), map() | nil) :: {:ok, keyword()} | {:error, term()}
  def prepare_chat_opts(opts, config \\ nil) when is_list(opts) do
    Jidoka.Agent.Chat.prepare_chat_opts(opts, config)
  end

  defmacro __using__(opts \\ []) do
    if opts != [] do
      raise CompileError,
        file: __CALLER__.file,
        line: __CALLER__.line,
        description:
          "Jidoka.Agent now uses a Spark DSL. Use `use Jidoka.Agent` and configure it inside `agent :id do ... end`."
    end

    quote location: :keep do
      use Jidoka.Agent.SparkDsl
      import Jidoka.Agent.Dsl.Forbidden

      @before_compile Jidoka.Agent
    end
  end

  defmacro __before_compile__(env) do
    Jidoka.Agent.Build.before_compile(env)
  end
end
