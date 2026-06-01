defmodule JidokaExample.DebugAgent.Targets do
  @moduledoc false

  alias Jidoka.Agent.Spec.Operation

  @targets [
    %{
      id: "support",
      label: "Support Agent",
      module: JidokaExample.SupportAgent.Agent,
      prompt: "Can you check order A1001?",
      context: %{}
    },
    %{
      id: "research",
      label: "Research Agent",
      module: JidokaExample.ResearchAgent.Agent,
      prompt: "What should I know about Runic workflows in Elixir?",
      context: %{}
    },
    %{
      id: "approval",
      label: "Approval Flow Agent",
      module: JidokaExample.ApprovalAgent.Agent,
      prompt: "Refund order B2002 for $25 because the package was late.",
      context: %{}
    },
    %{
      id: "ash",
      label: "Ash Agent",
      module: JidokaExample.AshAgent.Agent,
      prompt: "List the customers in the CRM.",
      context: %{}
    },
    %{
      id: "lead_quality",
      label: "Lead Quality Agent",
      module: JidokaExample.LeadQualityAgent.Agent,
      prompt: "Is Ada from Northwind a good lead?",
      context: %{}
    },
    %{
      id: "memory",
      label: "Memory Agent",
      module: JidokaExample.MemoryAgent.Agent,
      prompt: "Remember that I prefer concise answers.",
      context: %{}
    },
    %{
      id: "knowledge",
      label: "Knowledge Agent",
      module: JidokaExample.KnowledgeAgent.Agent,
      prompt: "Explain how Jidoka skills and MCP tools fit into the agent loop.",
      context: %{}
    },
    %{
      id: "kitchen_sink",
      label: "Kitchen Sink Agent",
      module: JidokaExample.KitchenSinkAgent.Agent,
      prompt: "Run the kitchen sink demo.",
      context: %{
        tenant: "demo",
        channel: "debug",
        session_id: "debug_preview",
        surface: "debug_agent",
        example: "debug_agent",
        actor: %{id: "debug-developer", role: "developer"}
      }
    }
  ]

  @spec all() :: [map()]
  def all, do: @targets

  @spec fetch(String.t() | atom()) :: {:ok, map()} | {:error, term()}
  def fetch(target) do
    id = normalize_id(target)

    case Enum.find(@targets, &(&1.id == id)) do
      nil -> {:error, {:unknown_debug_target, id, ids()}}
      target -> {:ok, target}
    end
  end

  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@targets, & &1.id)

  @spec inspect_target(String.t() | atom()) :: {:ok, map()} | {:error, term()}
  def inspect_target(target_id) do
    with {:ok, target} <- fetch(target_id) do
      spec = target.module.spec()
      operations = Enum.map(spec.operations, &operation_summary/1)
      controls = controls_summary(spec.controls)
      inspection = Jidoka.inspect(target.module)

      {:ok,
       %{
         "target" => target.id,
         "label" => target.label,
         "module" => Kernel.inspect(target.module),
         "agent_id" => spec.id,
         "operation_count" => length(operations),
         "operations" => operations,
         "controls" => controls,
         "inspection" => inspection
       }}
    end
  end

  @spec preflight_target(String.t() | atom(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def preflight_target(target_id, prompt) do
    with {:ok, target} <- fetch(target_id),
         {:ok, preflight} <-
           Jidoka.preflight(target.module, normalized_prompt(prompt, target),
             context: target.context,
             session_id: "debug_preview"
           ) do
      prompt = preflight.prompt
      messages = Enum.map(prompt.messages, &message_summary/1)

      operation_kinds =
        target.module.spec().operations
        |> Map.new(&{&1.name, &1 |> Operation.kind() |> to_string()})

      operations = Enum.map(prompt.operations, &operation_summary(&1, operation_kinds))

      {:ok,
       %{
         "target" => target.id,
         "label" => target.label,
         "module" => Kernel.inspect(target.module),
         "message_count" => length(messages),
         "operation_count" => length(operations),
         "messages" => messages,
         "operations" => operations,
         "timeline" => Enum.map(preflight.timeline, &timeline_summary/1)
       }}
    end
  end

  @spec preview(String.t() | atom(), String.t() | nil) :: map()
  def preview(target_id, prompt) do
    %{
      inspect: result_or_error(inspect_target(target_id)),
      preflight: result_or_error(preflight_target(target_id, prompt))
    }
  end

  defp normalized_prompt(nil, target), do: target.prompt

  defp normalized_prompt(prompt, target) do
    case prompt |> to_string() |> String.trim() do
      "" -> target.prompt
      prompt -> prompt
    end
  end

  defp normalize_id(target) do
    target
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp operation_summary(%Operation{} = operation) do
    %{
      "name" => operation.name,
      "kind" => operation |> Operation.kind() |> to_string(),
      "source" => operation.metadata["source"] || operation.metadata[:source] || "local"
    }
  end

  defp operation_summary(%{} = operation) do
    operation_summary(operation, %{})
  end

  defp operation_summary(%{} = operation, operation_kinds) do
    name = get(operation, :name)

    %{
      "name" => name,
      "kind" => Map.get(operation_kinds, name, operation |> get(:kind) |> to_string()),
      "source" => operation |> get(:metadata, %{}) |> get(:source, "local")
    }
  end

  defp controls_summary(nil) do
    %{"max_turns" => nil, "timeout_ms" => nil, "input" => 0, "operation" => 0, "output" => 0}
  end

  defp controls_summary(controls) do
    %{
      "max_turns" => controls.max_turns,
      "timeout_ms" => controls.timeout_ms,
      "input" => length(controls.inputs),
      "operation" => length(controls.operations),
      "output" => length(controls.outputs)
    }
  end

  defp message_summary(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => content}
  end

  defp message_summary(%{"role" => role, "content" => content}) do
    %{"role" => to_string(role), "content" => content}
  end

  defp timeline_summary(%{event: event, seq: seq}) do
    %{"event" => to_string(event), "seq" => seq}
  end

  defp timeline_summary(%{"event" => event, "seq" => seq}) do
    %{"event" => to_string(event), "seq" => seq}
  end

  defp result_or_error({:ok, value}), do: value
  defp result_or_error({:error, reason}), do: %{"error" => Jidoka.format_error(reason)}

  defp get(map, key, default \\ nil)

  defp get(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
