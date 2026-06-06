defmodule Jidoka.Agent.Dsl.Agent do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.any() |> Zoi.nullish(),
              model: Zoi.any() |> Zoi.nullish(),
              generation: Zoi.any() |> Zoi.nullish(),
              instructions: Zoi.any() |> Zoi.nullish(),
              description: Zoi.any() |> Zoi.nullish(),
              context: Zoi.any() |> Zoi.nullish(),
              result: Zoi.any() |> Zoi.nullish(),
              memory: Zoi.any() |> Zoi.nullish(),
              __spark_metadata__: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema
end

defmodule Jidoka.Agent.Dsl.Tool do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              module: Zoi.any() |> Zoi.nullish(),
              description: Zoi.any() |> Zoi.nullish(),
              idempotency: Zoi.any() |> Zoi.nullish(),
              approval: Zoi.any() |> Zoi.nullish(),
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

defmodule Jidoka.Agent.Dsl.AshResource do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              resource: Zoi.any() |> Zoi.nullish(),
              actions: Zoi.any() |> Zoi.nullish(),
              description: Zoi.any() |> Zoi.nullish(),
              idempotency: Zoi.any() |> Zoi.nullish(),
              approval: Zoi.any() |> Zoi.nullish(),
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

defmodule Jidoka.Agent.Dsl.Browser do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.any() |> Zoi.nullish(),
              mode: Zoi.any() |> Zoi.nullish(),
              allow: Zoi.any() |> Zoi.nullish(),
              description: Zoi.any() |> Zoi.nullish(),
              idempotency: Zoi.any() |> Zoi.nullish(),
              approval: Zoi.any() |> Zoi.nullish(),
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

defmodule Jidoka.Agent.Dsl.MCPTools do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              endpoint: Zoi.any() |> Zoi.nullish(),
              prefix: Zoi.any() |> Zoi.nullish(),
              tools: Zoi.any() |> Zoi.nullish(),
              required: Zoi.any() |> Zoi.nullish(),
              transport: Zoi.any() |> Zoi.nullish(),
              client_info: Zoi.any() |> Zoi.nullish(),
              protocol_version: Zoi.any() |> Zoi.nullish(),
              capabilities: Zoi.any() |> Zoi.nullish(),
              timeouts: Zoi.any() |> Zoi.nullish(),
              timeout: Zoi.any() |> Zoi.nullish(),
              description: Zoi.any() |> Zoi.nullish(),
              idempotency: Zoi.any() |> Zoi.nullish(),
              approval: Zoi.any() |> Zoi.nullish(),
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

defmodule Jidoka.Agent.Dsl.Catalog do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              catalog: Zoi.any() |> Zoi.nullish(),
              prefix: Zoi.any() |> Zoi.nullish(),
              description: Zoi.any() |> Zoi.nullish(),
              timeout: Zoi.any() |> Zoi.nullish(),
              max_calls: Zoi.any() |> Zoi.nullish(),
              max_parallel_calls: Zoi.any() |> Zoi.nullish(),
              require_read_only?: Zoi.any() |> Zoi.nullish(),
              result: Zoi.any() |> Zoi.nullish(),
              idempotency: Zoi.any() |> Zoi.nullish(),
              approval: Zoi.any() |> Zoi.nullish(),
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

defmodule Jidoka.Agent.Dsl.SkillRef do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              skill: Zoi.any() |> Zoi.nullish(),
              __spark_metadata__: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema
end

defmodule Jidoka.Agent.Dsl.SkillPath do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              path: Zoi.any() |> Zoi.nullish(),
              __spark_metadata__: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema
end

defmodule Jidoka.Agent.Dsl.Subagent do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              agent: Zoi.any() |> Zoi.nullish(),
              as: Zoi.any() |> Zoi.nullish(),
              description: Zoi.any() |> Zoi.nullish(),
              timeout: Zoi.any() |> Zoi.nullish(),
              forward_context: Zoi.any() |> Zoi.nullish(),
              result: Zoi.any() |> Zoi.nullish(),
              approval: Zoi.any() |> Zoi.nullish(),
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

defmodule Jidoka.Agent.Dsl.Handoff do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              agent: Zoi.any() |> Zoi.nullish(),
              as: Zoi.any() |> Zoi.nullish(),
              description: Zoi.any() |> Zoi.nullish(),
              target: Zoi.any() |> Zoi.nullish(),
              forward_context: Zoi.any() |> Zoi.nullish(),
              approval: Zoi.any() |> Zoi.nullish(),
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

defmodule Jidoka.Agent.Dsl.Workflow do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              workflow: Zoi.any() |> Zoi.nullish(),
              as: Zoi.any() |> Zoi.nullish(),
              description: Zoi.any() |> Zoi.nullish(),
              timeout: Zoi.any() |> Zoi.nullish(),
              async: Zoi.any() |> Zoi.nullish(),
              max_concurrency: Zoi.any() |> Zoi.nullish(),
              forward_context: Zoi.any() |> Zoi.nullish(),
              result: Zoi.any() |> Zoi.nullish(),
              idempotency: Zoi.any() |> Zoi.nullish(),
              approval: Zoi.any() |> Zoi.nullish(),
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

defmodule Jidoka.Agent.Dsl.OperationControl do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              control: Zoi.any() |> Zoi.nullish(),
              match: Zoi.any() |> Zoi.nullish(),
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

defmodule Jidoka.Agent.Dsl.InputControl do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              control: Zoi.any() |> Zoi.nullish(),
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

defmodule Jidoka.Agent.Dsl.OutputControl do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              control: Zoi.any() |> Zoi.nullish(),
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

defmodule Jidoka.Agent.Dsl.MaxTurnsControl do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              value: Zoi.any() |> Zoi.nullish(),
              __spark_metadata__: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema
end

defmodule Jidoka.Agent.Dsl.TimeoutControl do
  @moduledoc false

  @schema Zoi.struct(
            __MODULE__,
            %{
              value: Zoi.any() |> Zoi.nullish(),
              __spark_metadata__: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema
end
