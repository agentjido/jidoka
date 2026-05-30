defmodule Jidoka.Agent.Dsl.Agent do
  @moduledoc false

  defstruct [
    :id,
    :model,
    :generation,
    :instructions,
    :description,
    :context,
    :__spark_metadata__
  ]
end

defmodule Jidoka.Agent.Dsl.Tool do
  @moduledoc false

  defstruct [:module, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.OperationControl do
  @moduledoc false

  defstruct [:control, :match, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.InputControl do
  @moduledoc false

  defstruct [:control, :metadata, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.ResultControl do
  @moduledoc false

  defstruct [:control, :metadata, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.MaxTurnsControl do
  @moduledoc false

  defstruct [:value, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.TimeoutControl do
  @moduledoc false

  defstruct [:value, :__spark_metadata__]
end
