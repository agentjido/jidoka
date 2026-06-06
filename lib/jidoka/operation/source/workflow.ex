defmodule Jidoka.Operation.Source.Workflow do
  @moduledoc """
  Operation source for deterministic Jidoka workflows.

  The model sees one operation. The workflow module owns the deterministic
  step graph behind that operation. Sources can opt into async execution for
  independent workflow steps.
  """

  @behaviour Jidoka.Operation.Source

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Context
  alias Jidoka.Effect
  alias Jidoka.Schema
  alias Jidoka.Workflow.Spec

  @result_modes [:output, :structured]

  @type forward_context ::
          :public | :none | {:only, [atom() | String.t()]} | {:except, [atom() | String.t()]}
  @type result_mode :: :output | :structured

  @type t :: %__MODULE__{
          workflow: module(),
          name: String.t(),
          description: String.t() | nil,
          timeout: pos_integer(),
          async: boolean(),
          max_concurrency: pos_integer() | nil,
          forward_context: forward_context(),
          result: result_mode(),
          idempotency: Operation.idempotency(),
          metadata: map(),
          definition: Spec.t()
        }

  @schema Zoi.struct(
            __MODULE__,
            %{
              workflow: Zoi.atom() |> Zoi.nullish(),
              name: Zoi.string() |> Zoi.nullish(),
              description: Zoi.string() |> Zoi.nullish(),
              timeout: Zoi.integer() |> Zoi.default(30_000),
              async: Zoi.boolean() |> Zoi.default(false),
              max_concurrency: Zoi.integer() |> Zoi.nullish(),
              forward_context: Zoi.any() |> Zoi.default(:public),
              result: Schema.atom_enum(@result_modes) |> Zoi.default(:output),
              idempotency: Schema.atom_enum(Operation.valid_idempotencies()) |> Zoi.default(:idempotent),
              metadata: Zoi.map() |> Zoi.default(%{}),
              definition: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, definition} <- normalize_workflow(Schema.get_key(attrs, :workflow)),
         {:ok, name} <-
           normalize_name(
             Schema.get_key(attrs, :name) || Schema.get_key(attrs, :as),
             definition.id
           ),
         {:ok, timeout} <- normalize_timeout(Schema.get_key(attrs, :timeout, 30_000)),
         {:ok, async} <- normalize_async(Schema.get_key(attrs, :async, false)),
         {:ok, max_concurrency} <- normalize_max_concurrency(Schema.get_key(attrs, :max_concurrency)),
         {:ok, forward_context} <-
           normalize_forward_context(Schema.get_key(attrs, :forward_context, :public)),
         {:ok, result} <- normalize_result(Schema.get_key(attrs, :result, :output)),
         {:ok, idempotency} <- normalize_idempotency(Schema.get_key(attrs, :idempotency, :idempotent)),
         {:ok, metadata} <- normalize_metadata(Schema.get_key(attrs, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         workflow: definition.module,
         name: name,
         description: Schema.get_key(attrs, :description) || definition.description,
         timeout: timeout,
         async: async,
         max_concurrency: max_concurrency,
         forward_context: forward_context,
         result: result,
         idempotency: idempotency,
         metadata: metadata,
         definition: definition
       }}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, source} -> source
      {:error, reason} -> raise ArgumentError, "invalid workflow source: #{inspect(reason)}"
    end
  end

  @impl true
  def operations(%__MODULE__{} = source, _opts) do
    {:ok,
     [
       Operation.new!(
         name: source.name,
         description: source.description || "Run #{source.definition.id} workflow.",
         idempotency: source.idempotency,
         metadata:
           source.metadata
           |> Map.merge(%{
             "source" => "workflow",
             "kind" => "workflow",
             "workflow" => source.definition.id,
             "module" => inspect(source.workflow),
             "timeout" => source.timeout,
             "async" => source.async,
             "max_concurrency" => source.max_concurrency,
             "forward_context" => inspect(source.forward_context),
             "result" => Atom.to_string(source.result),
             "idempotency" => Atom.to_string(source.idempotency),
             "parameters_schema" => source.definition.parameters_schema
           })
           |> reject_nil_values()
       )
     ]}
  end

  @impl true
  def capability(%__MODULE__{} = source, _opts) do
    {:ok,
     fn
       %Effect.Intent{kind: :operation, payload: payload}, %Effect.Journal{}, %Context{} = context ->
         with {:ok, request} <- Effect.OperationRequest.from_input(payload),
              :ok <- ensure_operation_name(source, request.name),
              {:ok, output} <- run_workflow(source, request.arguments, context) do
           {:ok, workflow_result(source, output)}
         end

       %Effect.Intent{kind: kind}, _journal, %Context{} ->
         {:error, {:unsupported_effect_kind, kind}}
     end}
  end

  defp run_workflow(%__MODULE__{} = source, arguments, context) do
    task_context = child_context(source, context, arguments)

    task =
      Task.async(fn ->
        Jidoka.Workflow.run(source.workflow, arguments,
          context: task_context,
          timeout: source.timeout,
          async: source.async,
          max_concurrency: source.max_concurrency,
          agent_opts: agent_opts(context)
        )
      end)

    case Task.yield(task, source.timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, output}} -> {:ok, output}
      {:ok, {:error, reason}} -> {:error, {:workflow_failed, source.name, reason}}
      nil -> {:error, {:workflow_timeout, source.name, source.timeout}}
    end
  end

  defp workflow_result(%__MODULE__{result: :output}, output), do: output

  defp workflow_result(%__MODULE__{} = source, output) do
    %{
      workflow: source.definition.id,
      operation: source.name,
      output: output,
      module: inspect(source.workflow)
    }
  end

  defp child_context(%__MODULE__{} = source, parent_context, arguments) do
    arguments = normalize_context(arguments)
    runtime = runtime_context(parent_context)

    forwarded_data =
      parent_context
      |> public_context_data()
      |> normalize_context()
      |> forward_context(source.forward_context)

    case Schema.get_key(arguments, :context, %{}) do
      task_context when is_map(task_context) or is_list(task_context) ->
        Context.from_data!(
          Map.merge(forwarded_data, normalize_context(task_context)),
          runtime: runtime
        )

      _other ->
        Context.from_data!(forwarded_data, runtime: runtime)
    end
  end

  defp public_context_data(%Context{} = context), do: Context.data(context)
  defp public_context_data(context), do: normalize_context(context)

  defp runtime_context(%Context{} = context), do: Context.runtime(context)
  defp runtime_context(_context), do: %{}

  defp ensure_operation_name(%__MODULE__{name: expected}, name) do
    if name == expected, do: :ok, else: {:error, {:missing_operation_handler, name}}
  end

  defp forward_context(context, :public) when is_map(context), do: context
  defp forward_context(_context, :none), do: %{}

  defp forward_context(context, {:only, keys}) when is_map(context) and is_list(keys) do
    keys
    |> Enum.reduce(%{}, fn key, acc ->
      case fetch_context(context, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp forward_context(context, {:except, keys}) when is_map(context) and is_list(keys) do
    blocked = MapSet.new(Enum.flat_map(keys, &[&1, to_string(&1)]))
    Map.reject(context, fn {key, _value} -> MapSet.member?(blocked, key) end)
  end

  defp forward_context(_context, _policy), do: %{}

  defp fetch_context(context, key) when is_atom(key) do
    case Map.fetch(context, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(context, Atom.to_string(key))
    end
  end

  defp fetch_context(context, key), do: Map.fetch(context, key)

  defp normalize_workflow(workflow) when is_atom(workflow),
    do: Jidoka.Workflow.definition(workflow)

  defp normalize_workflow(workflow), do: {:error, {:invalid_workflow_module, workflow}}

  defp normalize_name(nil, default_name), do: normalize_name(default_name, default_name)

  defp normalize_name(name, _default_name) when is_atom(name) and not is_nil(name) do
    name |> Atom.to_string() |> normalize_name(nil)
  end

  defp normalize_name(name, _default_name) when is_binary(name) do
    name = String.trim(name)

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) do
      {:ok, name}
    else
      {:error, {:invalid_workflow_name, name}}
    end
  end

  defp normalize_name(name, _default_name), do: {:error, {:invalid_workflow_name, name}}

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: {:ok, timeout}
  defp normalize_timeout(timeout), do: {:error, {:invalid_workflow_timeout, timeout}}

  defp normalize_async(async) when is_boolean(async), do: {:ok, async}
  defp normalize_async(async), do: {:error, {:invalid_workflow_async, async}}

  defp normalize_max_concurrency(nil), do: {:ok, nil}

  defp normalize_max_concurrency(max_concurrency)
       when is_integer(max_concurrency) and max_concurrency > 0 do
    {:ok, max_concurrency}
  end

  defp normalize_max_concurrency(max_concurrency),
    do: {:error, {:invalid_workflow_max_concurrency, max_concurrency}}

  defp normalize_forward_context(policy) when policy in [:public, :none], do: {:ok, policy}

  defp normalize_forward_context({mode, keys} = policy)
       when mode in [:only, :except] and is_list(keys) do
    {:ok, policy}
  end

  defp normalize_forward_context(policy),
    do: {:error, {:invalid_workflow_forward_context, policy}}

  defp normalize_result(result) when result in @result_modes, do: {:ok, result}

  defp normalize_result(result) when is_binary(result) do
    @result_modes
    |> Enum.find(&(Atom.to_string(&1) == String.trim(result)))
    |> case do
      nil -> {:error, {:invalid_workflow_result, result}}
      result -> {:ok, result}
    end
  end

  defp normalize_result(result), do: {:error, {:invalid_workflow_result, result}}

  defp normalize_idempotency(idempotency) when is_atom(idempotency) do
    if idempotency in Operation.valid_idempotencies() do
      {:ok, idempotency}
    else
      {:error, {:invalid_workflow_idempotency, idempotency}}
    end
  end

  defp normalize_idempotency(idempotency) when is_binary(idempotency) do
    idempotency = String.trim(idempotency)

    Operation.valid_idempotencies()
    |> Enum.find(&(Atom.to_string(&1) == idempotency))
    |> case do
      nil -> {:error, {:invalid_workflow_idempotency, idempotency}}
      idempotency -> {:ok, idempotency}
    end
  end

  defp normalize_idempotency(idempotency), do: {:error, {:invalid_workflow_idempotency, idempotency}}

  defp normalize_metadata(nil), do: {:ok, %{}}
  defp normalize_metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  defp normalize_metadata(metadata), do: {:error, {:invalid_workflow_metadata, metadata}}

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp agent_opts(context) do
    case Context.get_runtime(context, :agent_opts, []) do
      opts when is_list(opts) -> opts
      _other -> []
    end
  end

  defp normalize_context(context) when is_map(context), do: context

  defp normalize_context(context) when is_list(context) do
    if Keyword.keyword?(context), do: Map.new(context), else: %{}
  end

  defp normalize_context(_context), do: %{}
end
