defmodule Jidoka.Agent.Dsl.Agent do
  @moduledoc false

  defstruct [
    :id,
    :model,
    :instructions,
    :character,
    :description,
    :context,
    :output,
    :__spark_metadata__
  ]
end

defmodule Jidoka.Agent.Dsl.Output do
  @moduledoc false

  defstruct [:schema, :retries, :on_validation_error, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.Tool do
  @moduledoc false

  defstruct [:module, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.AshResource do
  @moduledoc false

  defstruct [:resource, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.MCPTools do
  @moduledoc false

  defstruct [
    :endpoint,
    :prefix,
    :transport,
    :client_info,
    :protocol_version,
    :capabilities,
    :timeouts,
    :__spark_metadata__
  ]
end

defmodule Jidoka.Agent.Dsl.Plugin do
  @moduledoc false

  defstruct [:module, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.Web do
  @moduledoc false

  defstruct [:mode, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.SkillRef do
  @moduledoc false

  defstruct [:skill, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.SkillPath do
  @moduledoc false

  defstruct [:path, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.Subagent do
  @moduledoc false

  defstruct [
    :agent,
    :as,
    :description,
    :target,
    :timeout,
    :forward_context,
    :result,
    :__spark_metadata__
  ]
end

defmodule Jidoka.Agent.Dsl.Workflow do
  @moduledoc false

  defstruct [
    :workflow,
    :as,
    :description,
    :timeout,
    :forward_context,
    :result,
    :__spark_metadata__
  ]
end

defmodule Jidoka.Agent.Dsl.Handoff do
  @moduledoc false

  defstruct [
    :agent,
    :as,
    :description,
    :target,
    :forward_context,
    :__spark_metadata__
  ]
end

defmodule Jidoka.Agent.Dsl.Schedule do
  @moduledoc false

  defstruct [
    :name,
    :cron,
    :timezone,
    :prompt,
    :context,
    :conversation,
    :agent_id,
    :overlap,
    :timeout,
    :enabled?,
    :__spark_metadata__
  ]
end

defmodule Jidoka.Agent.Dsl.MemoryMode do
  @moduledoc false

  defstruct [:value, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.MemoryNamespace do
  @moduledoc false

  defstruct [:value, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.MemorySharedNamespace do
  @moduledoc false

  defstruct [:value, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.MemoryCapture do
  @moduledoc false

  defstruct [:value, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.MemoryInject do
  @moduledoc false

  defstruct [:value, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.MemoryRetrieve do
  @moduledoc false

  defstruct [:limit, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.CompactionMode do
  @moduledoc false

  defstruct [:value, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.CompactionStrategy do
  @moduledoc false

  defstruct [:value, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.CompactionMaxMessages do
  @moduledoc false

  defstruct [:value, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.CompactionKeepLast do
  @moduledoc false

  defstruct [:value, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.CompactionMaxSummaryChars do
  @moduledoc false

  defstruct [:value, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.CompactionPrompt do
  @moduledoc false

  defstruct [:value, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.BeforeTurnHook do
  @moduledoc false

  defstruct [:hook, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.AfterTurnHook do
  @moduledoc false

  defstruct [:hook, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.InterruptHook do
  @moduledoc false

  defstruct [:hook, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.InputGuardrail do
  @moduledoc false

  defstruct [:guardrail, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.OutputGuardrail do
  @moduledoc false

  defstruct [:guardrail, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.ToolGuardrail do
  @moduledoc false

  defstruct [:guardrail, :__spark_metadata__]
end
