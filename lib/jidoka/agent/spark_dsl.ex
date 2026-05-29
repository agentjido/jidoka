defmodule Jidoka.Agent.SparkDsl do
  @moduledoc false

  use Spark.Dsl, default_extensions: [extensions: [Jidoka.Agent.Dsl]]
end
