defmodule Jidoka.Workflow.SparkDsl do
  @moduledoc false

  use Spark.Dsl, default_extensions: [extensions: [Jidoka.Workflow.Dsl]]
end
