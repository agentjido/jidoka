defmodule Jidoka.Workflow.Dsl.ActionStep do
  @moduledoc false

  defstruct [:name, :module, :input, :after, :metadata, :__spark_metadata__]
end

defmodule Jidoka.Workflow.Dsl.FunctionStep do
  @moduledoc false

  defstruct [:name, :mfa, :input, :after, :metadata, :__spark_metadata__]
end

defmodule Jidoka.Workflow.Dsl.AgentStep do
  @moduledoc false

  defstruct [:name, :agent, :prompt, :context, :after, :metadata, :__spark_metadata__]
end
