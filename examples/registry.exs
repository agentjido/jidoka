defmodule JidokaExamples.Example do
  @moduledoc false

  @callback name() :: atom()
  @callback title() :: String.t()
  @callback features() :: [atom()]
  @callback summary() :: String.t()
  @callback run(keyword()) :: {:ok, map()} | {:error, term()}
end

defmodule JidokaExamples do
  @moduledoc false

  @root __DIR__

  @examples [
    %{
      name: :first_agent,
      title: "First Agent",
      dir: "first_agent",
      files: ["agents/assistant.ex", "example.exs"],
      module: JidokaExamples.FirstAgent,
      features: [:agent, :model, :instructions, :session, :prompt_preflight]
    },
    %{
      name: :ticket_classifier,
      title: "Ticket Classifier",
      dir: "ticket_classifier",
      files: ["agents/ticket_classifier.ex", "example.exs"],
      module: JidokaExamples.TicketClassifierExample,
      features: [:context, :result, :structured_output, :repair]
    },
    %{
      name: :support_agent,
      title: "Support Agent",
      dir: "support_agent",
      files: ["actions/load_ticket.ex", "controls/require_approval.ex", "agents/support_agent.ex", "example.exs"],
      module: JidokaExamples.SupportAgentExample,
      features: [:actions, :controls, :credentials, :human_in_the_loop]
    },
    %{
      name: :debug_agent,
      title: "Debug Agent",
      dir: "debug_agent",
      files: ["agents/debug_agent.ex", "example.exs"],
      module: JidokaExamples.DebugAgentExample,
      features: [:inspection, :trace, :interrupts]
    },
    %{
      name: :workflow_agent,
      title: "Workflow Agent",
      dir: "workflow_agent",
      files: [
        "actions/add_one.ex",
        "actions/double_value.ex",
        "workflows/math_workflow.ex",
        "agents/math_agent.ex",
        "example.exs"
      ],
      module: JidokaExamples.WorkflowAgentExample,
      features: [:workflow, :schedule, :workflow_tool]
    },
    %{
      name: :delegation_agent,
      title: "Delegation Agent",
      dir: "delegation_agent",
      files: [
        "actions/search_catalog.ex",
        "agents/research_specialist.ex",
        "agents/billing_specialist.ex",
        "agents/orchestrator.ex",
        "example.exs"
      ],
      module: JidokaExamples.DelegationAgentExample,
      features: [:subagent, :handoff, :imported_agent]
    },
    %{
      name: :knowledge_agent,
      title: "Knowledge Agent",
      dir: "knowledge_agent",
      files: [
        "actions/policy_lookup.ex",
        "actions/skill_policy_lookup.ex",
        "skills/policy_skill.ex",
        "plugins/policy_plugin.ex",
        "mcp/fake_mcp_sync.ex",
        "agents/knowledge_agent.ex",
        "example.exs"
      ],
      module: JidokaExamples.KnowledgeAgentExample,
      features: [:skills, :mcp_tools, :web]
    },
    %{
      name: :ash_agent,
      title: "Ash Resource Agent",
      dir: "ash_agent",
      files: ["resources/user.ex", "domains/accounts.ex", "agents/ash_agent.ex", "example.exs"],
      module: JidokaExamples.AshAgentExample,
      features: [:ash_resource, :actor_context]
    }
  ]

  @spec root() :: String.t()
  def root, do: @root

  @spec all() :: [map()]
  def all, do: @examples

  @spec names() :: [atom()]
  def names, do: Enum.map(@examples, & &1.name)

  @spec fetch(atom() | String.t()) :: {:ok, map()} | {:error, {:unknown_example, term(), [atom()]}}
  def fetch(name) do
    normalized = normalize_name(name)

    case Enum.find(@examples, &(&1.name == normalized)) do
      nil -> {:error, {:unknown_example, name, names()}}
      example -> {:ok, example}
    end
  end

  @spec run(atom() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(name, opts \\ []) when is_list(opts) do
    with {:ok, example} <- fetch(name),
         {:ok, _modules} <- load(example),
         {:ok, _apps} <- Application.ensure_all_started(:jidoka),
         :ok <- ensure_example_module(example.module) do
      example.module.run(Keyword.put_new(opts, :example, example))
    end
  end

  @spec load(map()) :: {:ok, [module()]} | {:error, term()}
  def load(%{dir: dir, files: files}) do
    example_root = Path.join(@root, dir)

    if File.dir?(example_root) do
      previous_options = Code.compiler_options()

      modules =
        try do
          Code.compiler_options(ignore_already_consolidated: true)

          files
          |> Enum.flat_map(fn file ->
            example_root
            |> Path.join(file)
            |> Code.require_file()
          end)
          |> Enum.map(fn {module, _binary} -> module end)
        after
          Code.compiler_options(ignore_already_consolidated: previous_options.ignore_already_consolidated)
        end

      {:ok, modules}
    else
      {:error, {:missing_example_dir, example_root}}
    end
  end

  @spec require_live_provider(keyword()) :: {:ok, String.t()} | {:error, term()}
  def require_live_provider(opts \\ []) do
    provider_env = Keyword.get(opts, :provider_env)

    result =
      if provider_env do
        Jidoka.Kino.load_provider_env(List.wrap(provider_env))
      else
        Jidoka.Kino.load_provider_env()
      end

    case result do
      {:ok, source} -> {:ok, source}
      {:error, message} -> {:error, {:missing_provider, message}}
    end
  end

  @spec mode(keyword()) :: :live | :verify
  def mode(opts), do: if(Keyword.get(opts, :live, false), do: :live, else: :verify)

  @spec prompt(keyword(), String.t()) :: String.t()
  def prompt(opts, default), do: opts |> Keyword.get(:prompt, default) |> to_string()

  @spec chat_summary(term()) :: map()
  def chat_summary({:ok, result}), do: %{status: :ok, result: Jidoka.Sanitize.preview(result, 800)}

  def chat_summary({:interrupt, %Jidoka.Interrupt{} = interrupt}) do
    %{
      status: :interrupt,
      kind: interrupt.kind,
      message: interrupt.message,
      data: Jidoka.Sanitize.payload(interrupt.data)
    }
  end

  def chat_summary({:handoff, %Jidoka.Handoff{} = handoff}) do
    %{
      status: :handoff,
      name: handoff.name,
      to_agent_id: handoff.to_agent_id,
      message: handoff.message,
      summary: handoff.summary,
      reason: handoff.reason
    }
  end

  def chat_summary({:error, reason}), do: %{status: :error, reason: Jidoka.Sanitize.preview(reason, 800)}
  def chat_summary(other), do: %{status: :unknown, result: Jidoka.Sanitize.preview(other, 800)}

  @spec live_chat_summary(term()) :: {:ok, map()} | {:error, term()}
  def live_chat_summary({:ok, _result} = outcome), do: {:ok, chat_summary(outcome)}
  def live_chat_summary({:interrupt, %Jidoka.Interrupt{}} = outcome), do: {:ok, chat_summary(outcome)}
  def live_chat_summary({:handoff, %Jidoka.Handoff{}} = outcome), do: {:ok, chat_summary(outcome)}
  def live_chat_summary({:error, reason}), do: {:error, reason}
  def live_chat_summary(other), do: {:error, {:unexpected_chat_result, other}}

  @spec feature_labels([atom()]) :: String.t()
  def feature_labels(features), do: features |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")

  defp ensure_example_module(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :run, 1) do
      :ok
    else
      {:error, {:invalid_example_module, module}}
    end
  end

  defp normalize_name(name) when is_atom(name), do: name

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.trim_leading(":")
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp normalize_name(name), do: name
end
