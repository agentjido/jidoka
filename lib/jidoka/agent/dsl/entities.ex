defmodule Jidoka.Agent.Dsl.Agent do
  @moduledoc false

  defstruct [
    :id,
    :model,
    :generation,
    :instructions,
    :description,
    :context,
    :result,
    :memory,
    :__spark_metadata__
  ]
end

defmodule Jidoka.Agent.Dsl.Tool do
  @moduledoc false

  defstruct [:module, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.AshResource do
  @moduledoc false

  defstruct [
    :resource,
    :actions,
    :description,
    :idempotency,
    :metadata,
    :__spark_metadata__
  ]
end

defmodule Jidoka.Agent.Dsl.Browser do
  @moduledoc false

  defstruct [
    :name,
    :mode,
    :allow,
    :description,
    :idempotency,
    :metadata,
    :__spark_metadata__
  ]
end

defmodule Jidoka.Agent.Dsl.Catalog do
  @moduledoc false

  defstruct [
    :name,
    :via,
    :providers,
    :only,
    :except,
    :max_results,
    :description,
    :idempotency,
    :metadata,
    :__spark_metadata__
  ]
end

defmodule Jidoka.Agent.Dsl.OperationControl do
  @moduledoc false

  defstruct [:control, :match, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.InputControl do
  @moduledoc false

  defstruct [:control, :metadata, :__spark_metadata__]
end

defmodule Jidoka.Agent.Dsl.OutputControl do
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
