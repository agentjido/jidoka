defmodule Jidoka.Operation.Source.Subagent do
  @moduledoc """
  Operation source for bounded subagent delegation.

  A subagent call runs one child agent turn and returns the child result to the
  parent. It does not change conversation ownership; handoffs own that separate
  routing concern.
  """

  @behaviour Jidoka.Operation.Source

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Context
  alias Jidoka.Effect
  alias Jidoka.Schema

  @result_modes [:text, :structured]

  @type forward_context ::
          :public | :none | {:only, [atom() | String.t()]} | {:except, [atom() | String.t()]}
  @type result_mode :: :text | :structured

  @type t :: %__MODULE__{
          agent: module(),
          name: String.t(),
          description: String.t() | nil,
          timeout: pos_integer(),
          forward_context: forward_context(),
          result: result_mode(),
          metadata: map()
        }

  @schema Zoi.struct(
            __MODULE__,
            %{
              agent: Zoi.atom() |> Zoi.nullish(),
              name: Zoi.string() |> Zoi.nullish(),
              description: Zoi.string() |> Zoi.nullish(),
              timeout: Zoi.integer() |> Zoi.default(30_000),
              forward_context: Zoi.any() |> Zoi.default(:public),
              result: Schema.atom_enum(@result_modes) |> Zoi.default(:structured),
              metadata: Zoi.map() |> Zoi.default(%{})
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

    with {:ok, agent} <- normalize_agent(Schema.get_key(attrs, :agent)),
         {:ok, name} <-
           normalize_name(Schema.get_key(attrs, :name) || Schema.get_key(attrs, :as), agent),
         {:ok, timeout} <- normalize_timeout(Schema.get_key(attrs, :timeout, 30_000)),
         {:ok, forward_context} <-
           normalize_forward_context(Schema.get_key(attrs, :forward_context, :public)),
         {:ok, result} <- normalize_result(Schema.get_key(attrs, :result, :structured)),
         {:ok, metadata} <- normalize_metadata(Schema.get_key(attrs, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         agent: agent,
         name: name,
         description: Schema.get_key(attrs, :description),
         timeout: timeout,
         forward_context: forward_context,
         result: result,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, source} -> source
      {:error, reason} -> raise ArgumentError, "invalid subagent source: #{inspect(reason)}"
    end
  end

  @impl true
  def operations(%__MODULE__{} = source, _opts) do
    {:ok,
     [
       Operation.new!(
         name: source.name,
         description:
           source.description ||
             "Delegate one bounded task to #{inspect(source.agent)} and return the result.",
         idempotency: :idempotent,
         metadata:
           source.metadata
           |> Map.merge(%{
             "source" => "subagent",
             "kind" => "subagent",
             "agent" => inspect(source.agent),
             "timeout" => source.timeout,
             "forward_context" => inspect(source.forward_context),
             "result" => Atom.to_string(source.result),
             "parameters_schema" => task_schema()
           })
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
              {:ok, task} <- task_from_arguments(request.arguments) do
           run_child(source, task, request.arguments, context)
         end

       %Effect.Intent{kind: kind}, _journal, %Context{} ->
         {:error, {:unsupported_effect_kind, kind}}
     end}
  end

  defp task_schema do
    %{
      "type" => "object",
      "properties" => %{
        "task" => %{"type" => "string", "description" => "Bounded task for the child agent."},
        "context" => %{"type" => "object", "description" => "Optional task-local context."}
      },
      "required" => ["task"]
    }
  end

  defp run_child(%__MODULE__{} = source, task, arguments, context) do
    request = [
      input: task,
      context: child_context(source, context, arguments)
    ]

    opts =
      [
        timeout: source.timeout,
        operation_context: Context.get_runtime(context, :subagent_operation_context, %{})
      ]
      |> maybe_put(:llm, Context.get_runtime(context, :subagent_llm))
      |> maybe_put(:memory_store, Context.get_runtime(context, :memory_store))
      |> maybe_put(:stream_to, Context.get_runtime(context, :stream_to))

    case apply(source.agent, :run_turn, [request, opts]) do
      {:ok, result} ->
        {:ok, child_result(source, result)}

      {:hibernate, snapshot} ->
        {:error, {:subagent_hibernated, source.name, snapshot.snapshot_id}}

      {:error, reason} ->
        {:error, {:subagent_failed, source.name, reason}}
    end
  end

  defp child_result(%__MODULE__{result: :text} = source, result) do
    %{subagent: source.name, agent: inspect(source.agent), content: result.content}
  end

  defp child_result(%__MODULE__{} = source, result) do
    %{
      subagent: source.name,
      agent: inspect(source.agent),
      content: result.content,
      value: result.value,
      operation_results: Enum.map(result.agent_state.operation_results, &project_operation_result/1)
    }
  end

  defp project_operation_result(result) do
    result
    |> Map.from_struct()
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp child_context(%__MODULE__{} = source, parent_context, arguments) do
    runtime = runtime_context(source, parent_context)

    forwarded_data =
      parent_context
      |> public_context_data()
      |> forward_context(source.forward_context)

    case Schema.get_key(arguments, :context, %{}) do
      task_context when is_map(task_context) ->
        Context.from_data!(Map.merge(forwarded_data, task_context), runtime: runtime)

      _other ->
        Context.from_data!(forwarded_data, runtime: runtime)
    end
  end

  defp public_context_data(%Context{} = context), do: Context.data(context)
  defp public_context_data(context) when is_map(context), do: context
  defp public_context_data(_context), do: %{}

  defp runtime_context(%__MODULE__{forward_context: :public}, %Context{} = context),
    do: Context.runtime(context)

  defp runtime_context(%__MODULE__{}, _context), do: %{}

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

  defp ensure_operation_name(%__MODULE__{name: expected}, name) do
    if name == expected, do: :ok, else: {:error, {:missing_operation_handler, name}}
  end

  defp task_from_arguments(arguments) do
    case Schema.get_key(arguments, :task) do
      task when is_binary(task) and task != "" -> {:ok, task}
      task -> {:error, {:invalid_subagent_task, task}}
    end
  end

  defp normalize_agent(agent) when is_atom(agent) do
    with {:module, _module} <- Code.ensure_compiled(agent),
         true <- function_exported?(agent, :spec, 0) do
      {:ok, agent}
    else
      {:error, reason} -> {:error, {:invalid_subagent_module, agent, reason}}
      false -> {:error, {:invalid_subagent_module, agent, :missing_spec}}
    end
  end

  defp normalize_agent(agent), do: {:error, {:invalid_subagent_module, agent}}

  defp normalize_name(nil, agent) do
    agent
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> normalize_name(agent)
  end

  defp normalize_name(name, _agent) when is_atom(name) and not is_nil(name) do
    name |> Atom.to_string() |> normalize_name(nil)
  end

  defp normalize_name(name, _agent) when is_binary(name) do
    name = String.trim(name)

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) do
      {:ok, name}
    else
      {:error, {:invalid_subagent_name, name}}
    end
  end

  defp normalize_name(name, _agent), do: {:error, {:invalid_subagent_name, name}}

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: {:ok, timeout}
  defp normalize_timeout(timeout), do: {:error, {:invalid_subagent_timeout, timeout}}

  defp normalize_forward_context(policy) when policy in [:public, :none], do: {:ok, policy}

  defp normalize_forward_context({mode, keys} = policy)
       when mode in [:only, :except] and is_list(keys) do
    {:ok, policy}
  end

  defp normalize_forward_context(policy),
    do: {:error, {:invalid_subagent_forward_context, policy}}

  defp normalize_result(result) when result in @result_modes, do: {:ok, result}

  defp normalize_result(result) when is_binary(result) do
    @result_modes
    |> Enum.find(&(Atom.to_string(&1) == String.trim(result)))
    |> case do
      nil -> {:error, {:invalid_subagent_result, result}}
      result -> {:ok, result}
    end
  end

  defp normalize_result(result), do: {:error, {:invalid_subagent_result, result}}

  defp normalize_metadata(nil), do: {:ok, %{}}
  defp normalize_metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  defp normalize_metadata(metadata), do: {:error, {:invalid_subagent_metadata, metadata}}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
