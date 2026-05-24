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

        capabilities do
          tool MyApp.Tools.AddNumbers
          ash_resource MyApp.Accounts.User
        end
      end

  Supported fields are intentionally limited:

  - `agent :id`
  - `agent.context` as an optional Zoi map/object schema for runtime context
  - `agent.model`
  - `agent.instructions` as a string, module callback, or MFA tuple
  - `agent.character` as an optional prompt/persona source
  - `capabilities` for tools, Ash resources, MCP tools, skills, plugins, subagents, and workflows
  - `lifecycle` for memory, hooks, and guardrails
  - `schedules` for first-class recurring agent turns registered by the application

  A nested runtime module is generated automatically and uses `Jido.AI.Agent`
  with the configured tool modules. The `capabilities` block currently supports
  explicit `Jidoka.Tool` modules and `ash_resource` expansion via `AshJido`.
  Subagent entries compile specialist agents into tool-like delegation
  capabilities while keeping the parent agent in control. Subagent entries can
  tune child `timeout`, public `forward_context`, and parent-visible `result`
  shape without introducing handoffs or workflow graphs.
  Workflow entries compile deterministic `Jidoka.Workflow` modules into
  tool-like capabilities while keeping ordered business processes in the
  workflow runtime.
  Character entries render structured persona data into the effective system
  prompt before `instructions`; per-request `character:` overrides can be
  supplied through `Jidoka.chat/3` or the generated agent `chat/3` function.
  Plugin entries accept `Jidoka.Plugin` modules and merge their declared
  action-backed tools into the same LLM-visible tool registry.
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

      @before_compile Jidoka.Agent
    end
  end

  defmacro __before_compile__(env) do
    Jidoka.Agent.Build.before_compile(env)
  end
end
