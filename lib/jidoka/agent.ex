defmodule Jidoka.Agent do
  @moduledoc """
  Spark-backed agent authoring surface for Jidoka.

  This DSL compiles a developer-friendly Jidoka agent definition into a
  `Jido.AI.Agent` runtime module while keeping the authoring surface focused on
  three sections: `agent`, `tools`, and `controls`.

  The first authoring surface is intentionally small:

      defmodule MyApp.ChatAgent do
        use Jidoka.Agent

        agent :chat_agent do
          model :fast
          instructions "You are a concise assistant."
          context Zoi.object(%{tenant: Zoi.string() |> Zoi.optional()})
        end

        tools do
          action MyApp.Tools.AddNumbers
          ash_resource MyApp.Accounts.User
        end
      end

  Supported fields are intentionally limited:

  - `agent :id`
  - `agent.context` as an optional Zoi map/object schema for runtime context
  - `agent.model`
  - `agent.instructions` as a string, module callback, or MFA tuple
  - `agent.character` as an optional prompt/persona source
  - `tools` for deterministic actions and model-callable integrations
  - `controls` for input, operation, and result policy

  Vocabulary:

  - context is caller-provided data for a turn
  - agent state belongs to the running process
  - memory, compaction, hooks, and schedules are runtime features, not agent DSL
  - result is the final app-facing value returned from a turn

  A nested runtime module is generated automatically and uses `Jido.AI.Agent`
  with the model-callable operation modules. The `tools` block accepts direct
  `Jidoka.Action` modules and higher-level integrations that expand into
  action-backed tools, such as Ash resources, MCP tools, skills, plugins,
  subagents, workflows, and handoffs.
  Subagent entries compile specialist agents into model-callable bounded
  delegation tools. The parent asks a child to handle one task, receives
  the result, and keeps ownership of future turns. Subagent entries can tune
  child `timeout`, public `forward_context`, and parent-visible `result` shape
  without introducing handoffs or workflow graphs.
  Handoff entries compile conversation ownership transfers. A successful
  handoff routes future turns for the conversation to the receiving agent until
  the owner is reset.
  Workflow entries expose deterministic `Jidoka.Workflow` modules as generated
  action-backed tools while keeping ordered business processes in the workflow
  runtime.
  Character entries render structured persona data into the effective system
  prompt before `instructions`; per-request `character:` overrides can be
  supplied through `Jidoka.chat/3` or the generated agent `chat/3` function.
  Plugin entries accept `Jidoka.Plugin` modules and merge their declared
  action-backed operations into the same model-callable operation surface.
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
