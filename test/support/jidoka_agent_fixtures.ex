defmodule JidokaTest.ChatAgent do
  use Jidoka.Agent

  agent :chat_agent do
    model :fast
    instructions "You are a concise assistant."
  end
end

defmodule JidokaTest.ScheduleCallbacks do
  @moduledoc false

  def support_digest_prompt, do: "Prepare the daily support digest."
  def support_digest_context, do: %{tenant: "demo", channel: "schedule"}
end

defmodule JidokaTest.CompactionPrompt do
  @moduledoc false

  def build_compaction_prompt(input) do
    "Custom compact #{input.source_message_count} messages."
  end
end

defmodule JidokaTest.CompactionPromptCallbacks do
  @moduledoc false

  def build(input, prefix), do: "#{prefix}: #{input.retained_message_count} retained."
end

defmodule JidokaTest.EmptyCompactionPrompt do
  @moduledoc false

  def build_compaction_prompt(_input), do: " "
end

defmodule JidokaTest.ErrorCompactionPrompt do
  @moduledoc false

  def build_compaction_prompt(_input), do: {:error, :prompt_failed}
end

defmodule JidokaTest.InvalidCompactionPrompt do
  @moduledoc false

  def build_compaction_prompt(_input), do: {:unexpected, :prompt}
end

defmodule JidokaTest.RaisingCompactionPrompt do
  @moduledoc false

  def build_compaction_prompt(_input), do: raise("prompt boom")
end

defmodule JidokaTest.MoreCompactionPromptCallbacks do
  @moduledoc false

  def ok(input, prefix), do: {:ok, "#{prefix}: #{input.source_message_count} source."}
  def error(_input), do: {:error, :mfa_failed}
  def empty(_input), do: {:ok, " "}
  def invalid(_input), do: {:unexpected, :mfa}
  def raise_error(_input), do: raise("mfa boom")
end

defmodule JidokaTest.CompactionSummarizer do
  @moduledoc false

  def summarize(input), do: {:ok, "module summary for #{input.source_message_count} messages"}
end

defmodule JidokaTest.ScheduledAgent do
  use Jidoka.Agent

  agent :scheduled_agent do
    model :fast
    instructions "You are a concise scheduled assistant."
  end

  def daily_digest_schedule do
    {:ok, schedule} =
      Jidoka.Schedule.new(__MODULE__,
        id: "scheduled_agent:daily_digest",
        agent_id: "scheduled_agent:daily_digest",
        cron: "0 9 * * *",
        timezone: "America/Chicago",
        prompt: {JidokaTest.ScheduleCallbacks, :support_digest_prompt, []},
        context: {JidokaTest.ScheduleCallbacks, :support_digest_context, []},
        conversation: "support-digest",
        overlap: :skip
      )

    schedule
  end
end

defmodule JidokaTest.ContextAgent do
  use Jidoka.Agent

  @context_fields %{
    tenant: Zoi.string() |> Zoi.default("demo"),
    channel: Zoi.string() |> Zoi.default("test"),
    session: Zoi.string() |> Zoi.optional()
  }

  agent :context_agent do
    model :fast
    instructions "You are a context-aware assistant."

    context(Zoi.object(@context_fields))
  end
end

defmodule JidokaTest.RequiredContextAgent do
  use Jidoka.Agent

  @context_fields %{
    account_id: Zoi.string(),
    tenant: Zoi.string() |> Zoi.default("demo")
  }

  agent :required_context_agent do
    model :fast
    instructions "You require account context."

    context(Zoi.object(@context_fields))
  end
end

defmodule JidokaTest.CompactionAgent do
  use Jidoka.Agent

  agent :compaction_agent do
    model :fast
    instructions "You have compaction."
  end

  def compaction_config do
    %{
      mode: :auto,
      strategy: :summary,
      max_messages: 4,
      keep_last: 2,
      max_summary_chars: 120,
      prompt: "Compact the transcript for this test."
    }
  end
end

defmodule JidokaTest.ManualCompactionAgent do
  use Jidoka.Agent

  agent :manual_compaction_agent do
    model :fast
    instructions "You have manual compaction."
  end

  def compaction_config do
    %{
      mode: :manual,
      strategy: :summary,
      max_messages: 4,
      keep_last: 2,
      max_summary_chars: 2_000,
      prompt: nil
    }
  end
end

defmodule JidokaTest.StructuredOutputGuardrail do
  use Jidoka.Guardrail, name: "structured_output_guardrail"

  @impl true
  def call(%Jidoka.Guardrails.Output{outcome: {:ok, %{category: _category}} = outcome, context: context}) do
    case Map.get(context, :notify_pid) do
      pid when is_pid(pid) -> send(pid, {:structured_output_guardrail, outcome})
      _other -> :ok
    end

    :ok
  end

  def call(_input), do: {:error, :expected_structured_output}
end

defmodule JidokaTest.StructuredOutputAgent do
  use Jidoka.Agent

  @output_schema Zoi.object(%{
                   category: Zoi.enum([:billing, :technical, :account]),
                   confidence: Zoi.float(),
                   summary: Zoi.string()
                 })

  agent :structured_output_agent do
    model :fast
    instructions "Classify the ticket and return the configured object."

    result @output_schema do
      repair(1)
      on_validation_error(:repair)
    end
  end

  controls do
    result(JidokaTest.StructuredOutputGuardrail)
  end
end

defmodule JidokaTest.StructuredOutputPlainAgent do
  use Jidoka.Agent

  @output_schema Zoi.object(%{
                   category: Zoi.enum([:billing, :technical, :account]),
                   confidence: Zoi.float(),
                   summary: Zoi.string()
                 })

  agent :structured_output_plain_agent do
    model :fast
    instructions "Classify the ticket and return the configured object."

    result @output_schema do
      repair(1)
      on_validation_error(:repair)
    end
  end
end

defmodule JidokaTest.StringModelAgent do
  use Jidoka.Agent

  agent :string_model_agent do
    model "openai:gpt-4.1"
    instructions "You are a concise assistant."
  end
end

defmodule JidokaTest.TenantPrompt do
  @behaviour Jidoka.Agent.SystemPrompt

  @impl true
  def resolve_system_prompt(%{context: context}) do
    tenant = Map.get(context, :tenant, Map.get(context, "tenant", "unknown"))
    "You are helping tenant #{tenant}."
  end
end

defmodule JidokaTest.PromptCallbacks do
  def build(%{context: context}, prefix) do
    tenant = Map.get(context, :tenant, Map.get(context, "tenant", "unknown"))
    {:ok, "#{prefix} #{tenant}."}
  end
end

defmodule JidokaTest.SupportCharacter do
  use Jido.Character,
    defaults: %{
      name: "Support Advisor",
      identity: %{role: "Support specialist"},
      voice: %{tone: :professional, style: "Practical and concise"},
      instructions: ["Use the configured support persona."]
    }
end

defmodule JidokaTest.ModulePromptAgent do
  use Jidoka.Agent

  agent :module_prompt_agent do
    model :fast
    instructions JidokaTest.TenantPrompt
  end
end

defmodule JidokaTest.MfaPromptAgent do
  use Jidoka.Agent

  agent :mfa_prompt_agent do
    model :fast
    instructions {JidokaTest.PromptCallbacks, :build, ["Serve tenant"]}
  end
end

defmodule JidokaTest.CharacterAgent do
  use Jidoka.Agent

  agent :character_agent do
    model :fast

    character(%{
      name: "Policy Advisor",
      identity: %{role: "Support policy specialist"},
      voice: %{tone: :professional, style: "Clear and direct"},
      instructions: ["Stay within published policy."]
    })

    instructions "Answer with the support policy first."
  end
end

defmodule JidokaTest.ModuleCharacterAgent do
  use Jidoka.Agent

  agent :module_character_agent do
    model :fast
    character(JidokaTest.SupportCharacter)
    instructions "Adapt the response to the account tier."
  end
end

defmodule JidokaTest.InlineMapModelAgent do
  use Jidoka.Agent

  agent :inline_map_model_agent do
    model %{provider: :openai, id: "gpt-4.1", base_url: "http://localhost:4000/v1"}
    instructions "You are a concise assistant."
  end
end

defmodule JidokaTest.StructModelAgent do
  use Jidoka.Agent

  agent :struct_model_agent do
    model %LLMDB.Model{provider: :openai, id: "gpt-4.1"}
    instructions "You are a concise assistant."
  end
end
