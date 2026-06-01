defmodule JidokaExample.KnowledgeAgent.Skills.KnowledgeTopicLookup do
  @moduledoc false

  use Jidoka.Action,
    name: "knowledge_topic_lookup",
    description: "Looks up local Jidoka implementation notes for a developer-facing topic.",
    schema:
      Zoi.object(%{
        topic: Zoi.string() |> Zoi.default("jidoka")
      })

  @notes %{
    "controls" => %{
      "summary" =>
        "Controls are boundary policies around input, operation planning, and final output.",
      "details" => [
        "input controls can reject unsafe user input before prompt assembly",
        "operation controls can interrupt a planned effect for review",
        "output controls validate structured final results before completion"
      ]
    },
    "mcp" => %{
      "summary" =>
        "MCP tools compile into ordinary Jidoka operations with metadata that records their source.",
      "details" => [
        "the LLM sees the normalized operation name",
        "the operation source routes the call back to the MCP endpoint",
        "the result enters the same operation observation path as local actions"
      ]
    },
    "skills" => %{
      "summary" =>
        "Skills contribute prompt guidance and Jido action modules without becoming a second runtime.",
      "details" => [
        "skill actions are still executed as Jidoka operation effects",
        "skill prompt text is folded into the agent instructions",
        "skill metadata is visible in the compiled AgentSpec"
      ]
    },
    "runic" => %{
      "summary" =>
        "Runic provides the data-first turn spine that assembles prompts, plans effects, and records observations.",
      "details" => [
        "turn state is data that can be inspected and serialized",
        "effects cross explicit capability boundaries",
        "hibernate/resume works by checkpointing phase-boundary state"
      ]
    }
  }

  @impl true
  def run(params, _context) do
    topic = params |> get(:topic, "jidoka") |> normalize_topic()
    note = Map.get(@notes, topic, default_note(topic))

    {:ok,
     %{
       "topic" => topic,
       "summary" => note["summary"],
       "details" => note["details"]
     }}
  end

  defp get(params, key, default),
    do: Map.get(params, key, Map.get(params, Atom.to_string(key), default))

  defp normalize_topic(topic) do
    topic
    |> to_string()
    |> String.downcase()
    |> condense_topic()
  end

  defp condense_topic(topic) do
    cond do
      String.contains?(topic, "control") -> "controls"
      String.contains?(topic, "mcp") -> "mcp"
      String.contains?(topic, "skill") -> "skills"
      String.contains?(topic, "runic") -> "runic"
      true -> "jidoka"
    end
  end

  defp default_note(topic) do
    %{
      "summary" => "Jidoka is a thin, data-driven agent harness over the Jido ecosystem.",
      "details" => [
        "agents compile into immutable AgentSpec data",
        "turns execute through a constrained Runic-backed loop",
        "capabilities plug into the loop as operation sources"
      ],
      "topic" => topic
    }
  end
end
