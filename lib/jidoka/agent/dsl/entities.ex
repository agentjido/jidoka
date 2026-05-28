defmodule Jidoka.Agent.Dsl.Agent do
  @moduledoc false

  defstruct [
    :id,
    :model,
    :instructions,
    :character,
    :description,
    :context,
    :result,
    :__spark_metadata__
  ]
end

defmodule Jidoka.Agent.Dsl.Result do
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
    :required,
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

defmodule Jidoka.Agent.Dsl.InputControl do
  @moduledoc false

  defstruct [:control, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.ResultControl do
  @moduledoc false

  defstruct [:control, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.OperationControl do
  @moduledoc false

  defstruct [:control, :match, :__spark_metadata__]
end
