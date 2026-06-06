defmodule Jidoka.Workflow.Dsl.ActionStep do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              :name => Zoi.any() |> Zoi.nullish(),
              :module => Zoi.any() |> Zoi.nullish(),
              :input => Zoi.any() |> Zoi.nullish(),
              :after => Zoi.any() |> Zoi.nullish(),
              :when => Zoi.any() |> Zoi.nullish(),
              :unless => Zoi.any() |> Zoi.nullish(),
              :retry => Zoi.any() |> Zoi.nullish(),
              :metadata => Zoi.any() |> Zoi.nullish(),
              :__spark_metadata__ => Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema
end

defmodule Jidoka.Workflow.Dsl.FunctionStep do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              :name => Zoi.any() |> Zoi.nullish(),
              :mfa => Zoi.any() |> Zoi.nullish(),
              :input => Zoi.any() |> Zoi.nullish(),
              :after => Zoi.any() |> Zoi.nullish(),
              :when => Zoi.any() |> Zoi.nullish(),
              :unless => Zoi.any() |> Zoi.nullish(),
              :retry => Zoi.any() |> Zoi.nullish(),
              :metadata => Zoi.any() |> Zoi.nullish(),
              :__spark_metadata__ => Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema
end

defmodule Jidoka.Workflow.Dsl.AgentStep do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              :name => Zoi.any() |> Zoi.nullish(),
              :agent => Zoi.any() |> Zoi.nullish(),
              :prompt => Zoi.any() |> Zoi.nullish(),
              :context => Zoi.any() |> Zoi.nullish(),
              :after => Zoi.any() |> Zoi.nullish(),
              :when => Zoi.any() |> Zoi.nullish(),
              :unless => Zoi.any() |> Zoi.nullish(),
              :retry => Zoi.any() |> Zoi.nullish(),
              :metadata => Zoi.any() |> Zoi.nullish(),
              :__spark_metadata__ => Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema
end

defmodule Jidoka.Workflow.Dsl.GateStep do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.any() |> Zoi.nullish(),
              condition: Zoi.any() |> Zoi.nullish(),
              after: Zoi.any() |> Zoi.nullish(),
              metadata: Zoi.any() |> Zoi.nullish(),
              __spark_metadata__: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema
end

defmodule Jidoka.Workflow.Dsl.MapStep do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              :name => Zoi.any() |> Zoi.nullish(),
              :over => Zoi.any() |> Zoi.nullish(),
              :function => Zoi.any() |> Zoi.nullish(),
              :action => Zoi.any() |> Zoi.nullish(),
              :params => Zoi.any() |> Zoi.nullish(),
              :after => Zoi.any() |> Zoi.nullish(),
              :when => Zoi.any() |> Zoi.nullish(),
              :unless => Zoi.any() |> Zoi.nullish(),
              :retry => Zoi.any() |> Zoi.nullish(),
              :max_concurrency => Zoi.any() |> Zoi.nullish(),
              :metadata => Zoi.any() |> Zoi.nullish(),
              :__spark_metadata__ => Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema
end

defmodule Jidoka.Workflow.Dsl.ReduceStep do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              :name => Zoi.any() |> Zoi.nullish(),
              :over => Zoi.any() |> Zoi.nullish(),
              :using => Zoi.any() |> Zoi.nullish(),
              :params => Zoi.any() |> Zoi.nullish(),
              :after => Zoi.any() |> Zoi.nullish(),
              :when => Zoi.any() |> Zoi.nullish(),
              :unless => Zoi.any() |> Zoi.nullish(),
              :retry => Zoi.any() |> Zoi.nullish(),
              :metadata => Zoi.any() |> Zoi.nullish(),
              :__spark_metadata__ => Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema
end
