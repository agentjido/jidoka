defmodule Jidoka.Extension.Host do
  @moduledoc "Trusted host for resolved built-in and process-shaped extension factories."

  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Extension.{Binding, Dispatcher, Error, OperationSource, Request, Resolver, Slot}
  alias Jidoka.Session.Data, as: Session

  @enforce_keys [:session_id, :mode, :bindings, :instances, :dispatcher]
  defstruct [:session_id, :mode, :bindings, :instances, :dispatcher]

  @type instance :: %{binding: Binding.t(), request: Request.t(), value: term(), slots: Slot.t()}
  @type t :: %__MODULE__{
          session_id: String.t(),
          mode: :interactive | :automation,
          bindings: [Binding.t()],
          instances: [instance()],
          dispatcher: pid()
        }

  @doc "Merges default and trusted replacement registry entries and removes disabled IDs."
  @spec registry(map(), map(), [String.t()]) :: map()
  def registry(defaults, replacements \\ %{}, disabled_ids \\ []) do
    defaults
    |> Map.merge(replacements)
    |> Map.drop(disabled_ids)
  end

  @doc "Resolves requests and opens their trusted factories for one session."
  @spec open(Session.t(), [Request.t()], map(), :interactive | :automation, keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def open(%Session{} = session, requests, registry, mode, opts \\ []) do
    with {:ok, bindings} <- Resolver.resolve_all(requests, registry, mode, opts),
         {:ok, instances} <- open_instances(bindings, requests, registry, session, []) do
      finalize_open(session, mode, bindings, instances, opts)
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, code, details} -> {:error, Error.new(code, details)}
    end
  end

  defp finalize_open(session, mode, bindings, instances, opts) do
    with :ok <- validate_collisions(instances),
         {:ok, dispatcher} <- start_dispatcher(instances, opts) do
      {:ok,
       %__MODULE__{
         session_id: session.session_id,
         mode: mode,
         bindings: bindings,
         instances: instances,
         dispatcher: dispatcher
       }}
    else
      reason ->
        Enum.each(instances, &close_instance/1)

        case reason do
          {:error, code, details} -> {:error, Error.new(code, details)}
          {:error, other} -> {:error, Error.new(:extension_host_open_failed, %{reason: inspect(other)})}
        end
    end
  end

  @doc "Opens a host for one callback and always closes all opened instances."
  @spec with_open(Session.t(), [Request.t()], map(), :interactive | :automation, keyword(), (t() -> term())) ::
          term()
  def with_open(%Session{} = session, requests, registry, mode, opts \\ [], callback)
      when is_function(callback, 1) do
    case open(session, requests, registry, mode, opts) do
      {:ok, host} ->
        try do
          callback.(host)
        after
          close(host)
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @doc "Returns operation sources. Normal Jidoka execution keeps the policy gate authoritative."
  @spec operation_sources(t()) :: [OperationSource.t()]
  def operation_sources(%__MODULE__{instances: instances}) do
    Enum.map(instances, fn instance ->
      %OperationSource{
        namespace: instance.slots.namespace,
        operations: instance.slots.tools,
        handlers: instance.slots.tool_handlers
      }
    end)
  end

  @doc "Returns provider callbacks by stable ID, with collision checks done at open."
  @spec providers(t()) :: map()
  def providers(%__MODULE__{instances: instances}),
    do: merge_slot_maps(instances, :providers)

  @doc "Returns deterministic command callbacks by stable ID."
  @spec commands(t()) :: map()
  def commands(%__MODULE__{instances: instances}),
    do: merge_slot_maps(instances, :commands)

  @doc "Collects namespaced pre-turn context."
  @spec context(t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def context(%__MODULE__{instances: instances}, turn_context) when is_map(turn_context) do
    reduce_callbacks(
      instances,
      :context,
      %{},
      fn namespace, value, acc ->
        with true <- is_map(value),
             :ok <- Contract.validate_safe_map(value) do
          {:ok, Map.put(acc, namespace, Contract.project(value))}
        else
          reason -> {:error, Error.new(:extension_context_invalid, %{namespace: namespace, reason: inspect(reason)})}
        end
      end,
      [turn_context]
    )
  end

  @doc "Returns advisory policy data. The host policy gate can ignore or deny it."
  @spec policy_advice(t(), term()) :: {:ok, map()} | {:error, Error.t()}
  def policy_advice(%__MODULE__{instances: instances}, intent) do
    reduce_callbacks(
      instances,
      :policy_advice,
      %{},
      fn namespace, value, acc ->
        with true <- is_map(value), :ok <- Contract.validate_safe_map(value) do
          {:ok, Map.put(acc, namespace, Contract.project(value))}
        else
          reason ->
            {:error, Error.new(:extension_policy_advice_invalid, %{namespace: namespace, reason: inspect(reason)})}
        end
      end,
      [intent]
    )
  end

  @doc "Checkpoints portable namespaced state into durable session metadata."
  @spec checkpoint(t(), Session.t()) :: {:ok, Session.t()} | {:error, Error.t()}
  def checkpoint(%__MODULE__{instances: instances}, %Session{} = session) do
    reduce_callbacks(instances, :checkpoint, %{}, &put_portable_namespace/3, [])
    |> case do
      {:ok, states} ->
        case Session.put_extension_state(session, states) do
          {:ok, updated} -> {:ok, updated}
          {:error, reason} -> {:error, Error.new(:extension_checkpoint_invalid, %{reason: inspect(reason)})}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @doc "Projects only registered namespaced result data."
  @spec results(t()) :: {:ok, map()} | {:error, Error.t()}
  def results(%__MODULE__{instances: instances}) do
    Enum.reduce_while(instances, {:ok, %{}}, fn instance, {:ok, acc} ->
      case put_portable_namespace(instance.slots.namespace, instance.slots.result, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc "Projects only registered namespaced portable UI data."
  @spec ui_data(t()) :: {:ok, map()} | {:error, Error.t()}
  def ui_data(%__MODULE__{instances: instances}) do
    Enum.reduce_while(instances, {:ok, %{}}, fn instance, {:ok, acc} ->
      case put_portable_namespace(instance.slots.namespace, instance.slots.ui_data, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc "Closes every opened instance and returns stable evidence for all outcomes."
  @spec close(t()) :: {:ok, [map()]}
  def close(%__MODULE__{instances: instances, dispatcher: dispatcher}) do
    evidence = Enum.reverse(instances) |> Enum.map(&close_instance/1)
    stop_dispatcher(dispatcher)
    {:ok, evidence}
  end

  defp stop_dispatcher(dispatcher) do
    GenServer.stop(dispatcher, :normal)
  catch
    :exit, {:noproc, _call} -> :ok
  end

  defp open_instances([], _requests, _registry, _session, opened), do: {:ok, Enum.reverse(opened)}

  defp open_instances([binding | rest], requests, registry, session, opened) do
    request = Enum.find(requests, &(Request.instance_key(&1) == binding.instance_key))

    with {:ok, entry} <- Map.fetch(registry, request.id),
         {:ok, factory} <- factory(entry),
         restored = Session.extension_state(session) |> Map.get(binding.instance_key, %{}),
         {:ok, value, slots_input} <-
           call_open(factory, binding, request.config, %{session_id: session.session_id, state: restored}),
         {:ok, slots} <- Slot.new(slots_input),
         true <- slots.namespace == binding.instance_key do
      instance = %{binding: binding, request: request, value: value, slots: slots}
      open_instances(rest, requests, registry, session, [instance | opened])
    else
      reason ->
        Enum.each(opened, &close_instance/1)
        {:error, :extension_factory_failed, %{instance_key: binding.instance_key, reason: inspect(reason)}}
    end
  end

  defp factory(%{factory: factory}), do: {:ok, factory}
  defp factory(_entry), do: {:error, :missing_extension_factory}

  defp call_open(factory, binding, config, context) when is_function(factory, 3),
    do: safe_call(fn -> factory.(binding, config, context) end)

  defp call_open(factory, binding, config, context) when is_atom(factory) do
    if function_exported?(factory, :open, 3),
      do: safe_call(fn -> factory.open(binding, config, context) end),
      else: {:error, :invalid_extension_factory}
  end

  defp call_open(_factory, _binding, _config, _context), do: {:error, :invalid_extension_factory}

  defp start_dispatcher(instances, opts) do
    subscribers = instances |> Enum.map(& &1.slots.lifecycle) |> Enum.reject(&is_nil/1)
    Dispatcher.start_link(subscribers: subscribers, timeout_ms: Keyword.get(opts, :handler_timeout_ms, 100))
  end

  defp validate_collisions(instances) do
    fields = [:namespace, :tools, :commands, :providers]

    Enum.reduce_while(fields, :ok, fn field, :ok ->
      ids = slot_ids(instances, field)

      if length(ids) == length(Enum.uniq(ids)),
        do: {:cont, :ok},
        else: {:halt, {:error, :extension_slot_collision, %{slot: field}}}
    end)
  end

  defp slot_ids(instances, :namespace), do: Enum.map(instances, & &1.slots.namespace)
  defp slot_ids(instances, :tools), do: Enum.flat_map(instances, &Enum.map(&1.slots.tools, fn tool -> tool.name end))
  defp slot_ids(instances, field), do: Enum.flat_map(instances, &Map.keys(Map.fetch!(&1.slots, field)))

  defp merge_slot_maps(instances, field),
    do: Enum.reduce(instances, %{}, &Map.merge(&2, Map.fetch!(&1.slots, field)))

  defp reduce_callbacks(instances, field, initial, merge, args) do
    Enum.reduce_while(instances, {:ok, initial}, fn instance, {:ok, acc} ->
      callback = Map.fetch!(instance.slots, field)

      result = callback_result(callback, field, instance, args)
      callback_step(result, instance.slots.namespace, acc, merge)
    end)
  end

  defp callback_step(:skip, _namespace, acc, _merge), do: {:cont, {:ok, acc}}

  defp callback_step({:ok, value}, namespace, acc, merge) do
    case merge.(namespace, value, acc) do
      {:ok, next} -> {:cont, {:ok, next}}
      {:error, %Error{} = error} -> {:halt, {:error, error}}
    end
  end

  defp callback_step({:error, reason}, namespace, _acc, _merge),
    do: handler_halt(namespace, reason)

  defp callback_step(other, namespace, _acc, _merge),
    do: handler_halt(namespace, other)

  defp handler_halt(namespace, reason) do
    {:halt,
     {:error,
      Error.new(:extension_handler_failed, %{
        namespace: namespace,
        reason: inspect(reason)
      })}}
  end

  defp callback_result(nil, :checkpoint, instance, _args), do: {:ok, instance.slots.state}
  defp callback_result(nil, _field, _instance, _args), do: :skip

  defp callback_result(callback, _field, instance, args),
    do: safe_call(fn -> apply(callback, [instance.value | args]) end)

  defp put_portable_namespace(namespace, value, acc) do
    with true <- namespace != "core",
         true <- is_map(value),
         :ok <- Contract.validate_safe_map(value) do
      {:ok, Map.put(acc, namespace, Contract.project(value))}
    else
      reason -> {:error, Error.new(:extension_namespace_data_invalid, %{namespace: namespace, reason: inspect(reason)})}
    end
  end

  defp close_instance(instance) do
    case instance.slots.close do
      nil ->
        %{"namespace" => instance.slots.namespace, "status" => "closed"}

      callback ->
        case safe_call(fn -> callback.(instance.value) end) do
          :ok -> %{"namespace" => instance.slots.namespace, "status" => "closed"}
          {:ok, _value} -> %{"namespace" => instance.slots.namespace, "status" => "closed"}
          reason -> %{"namespace" => instance.slots.namespace, "status" => "close_failed", "reason" => inspect(reason)}
        end
    end
  end

  defp safe_call(function) do
    function.()
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
