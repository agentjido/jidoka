defmodule Jidoka.Extension.ProcessHost do
  @moduledoc "Supervised bridge from a trusted process descriptor to extension host slots."

  use GenServer

  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Extension.{Binding, Error, Protocol, Slot}
  alias Jidoka.Extension.ProcessHost.Manifest

  @default_timeout 1_000

  @doc "Starts one supervised process extension and completes its pinned handshake."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Starts one host and returns a stable startup error."
  @spec start(keyword()) :: {:ok, pid()} | {:error, Error.t()}
  def start(opts) do
    case GenServer.start(__MODULE__, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, Error.new(:process_extension_start_failed, %{reason: redact(reason)})}
    end
  end

  @doc "Returns a built-in host factory backed by this process bridge."
  @spec factory(map(), keyword()) :: function()
  def factory(descriptor, opts \\ []) do
    fn binding, config, context ->
      start_opts = [binding: binding, descriptor: descriptor, config: config, context: context] ++ opts

      with {:ok, pid} <- start(start_opts),
           {:ok, slots} <- slots(pid) do
        {:ok, pid, slots}
      end
    end
  end

  @doc "Returns live slots declared by the verified process manifest."
  @spec slots(pid()) :: {:ok, Slot.t()} | {:error, Error.t()}
  def slots(pid), do: GenServer.call(pid, :slots)

  @doc "Makes one bounded correlated protocol call."
  @spec call(pid(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def call(pid, method, params, opts \\ []), do: GenServer.call(pid, {:call, method, params, opts}, :infinity)

  @doc "Sends one private protocol notification."
  @spec notify(pid(), String.t(), map()) :: :ok | {:error, Error.t()}
  def notify(pid, method, params), do: GenServer.call(pid, {:notify, method, params})

  @doc "Returns redacted transport diagnostics."
  @spec diagnostics(pid()) :: map()
  def diagnostics(pid), do: GenServer.call(pid, :diagnostics)

  @doc "Shuts down protocol and transport. Cleanup always runs."
  @spec close(pid(), keyword()) :: :ok | {:error, Error.t()}
  def close(pid, opts \\ []) do
    try do
      GenServer.call(pid, {:close, opts}, :infinity)
    catch
      :exit, _reason -> :ok
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with %Binding{} = binding <- Keyword.get(opts, :binding),
         true <- binding.identity.source_type == :process,
         descriptor when is_map(descriptor) <- Keyword.get(opts, :descriptor),
         transport when is_atom(transport) <- Map.get(descriptor, :transport),
         true <- function_exported?(transport, :open, 2),
         {:ok, handle, evidence} <- safe_transport(fn -> transport.open(descriptor, opts) end) do
      finish_init(binding, descriptor, transport, handle, evidence, opts)
    else
      reason -> {:stop, {:process_extension_start_failed, redact(reason)}}
    end
  end

  defp finish_init(binding, descriptor, transport, handle, evidence, opts) do
    result =
      with :ok <- validate_launch(binding, Keyword.get(opts, :mode, binding.mode), evidence),
           {:ok, protocol, next_handle, manifest} <- handshake(binding, transport, handle, opts),
           {:ok, protocol, next_handle} <-
             maybe_restore(protocol, transport, next_handle, Keyword.get(opts, :context, %{}), opts) do
        {:ok,
         %{
           binding: binding,
           descriptor: descriptor,
           transport: transport,
           handle: next_handle,
           protocol: protocol,
           manifest: manifest,
           timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout),
           next_id: 1,
           closed?: false
         }}
      end

    case result do
      {:ok, state} ->
        {:ok, state}

      reason ->
        _cleanup = safe_transport(fn -> transport.close(handle, reason: :startup_failed) end)
        {:stop, {:process_extension_start_failed, redact(reason)}}
    end
  end

  @impl true
  def handle_call(:slots, _from, state), do: {:reply, build_slots(state), state}

  def handle_call({:call, method, params, opts}, {caller, _tag}, state) do
    timeout = Keyword.get(opts, :timeout_ms, state.timeout_ms)

    case protocol_call(state, method, params, timeout, caller) do
      {:ok, result, next} -> {:reply, {:ok, result}, next}
      {:error, %Error{} = error, next} -> {:reply, {:error, error}, next}
    end
  end

  def handle_call({:notify, method, params}, _from, state) do
    with {:ok, frame} <- Protocol.notification(state.protocol, method, params),
         {:ok, handle} <- safe_transport(fn -> state.transport.notify(state.handle, frame) end) do
      {:reply, :ok, %{state | handle: handle}}
    else
      reason -> {:reply, {:error, error(:process_extension_notification_failed, reason, state)}, state}
    end
  end

  def handle_call(:diagnostics, _from, state),
    do: {:reply, transport_diagnostics(state), state}

  def handle_call({:close, opts}, _from, state) do
    {reply, next} = close_state(state, opts)
    {:stop, :normal, reply, next}
  end

  @impl true
  def terminate(_reason, %{closed?: false} = state) do
    _result = safe_transport(fn -> state.transport.close(state.handle, reason: :owner_exit) end)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp handshake(binding, transport, handle, opts) do
    protocol = Protocol.new(binding)
    id = "initialize-1"
    mode = Keyword.get(opts, :mode, binding.mode)

    with {:ok, frame, protocol} <- Protocol.initialize(protocol, id, mode),
         {:ok, line, handle} <- safe_transport(fn -> transport.exchange(handle, frame, timeout(opts)) end),
         {:ok, %{"result" => raw_manifest}, protocol} <- Protocol.receive_line(protocol, line),
         {:ok, protocol} <- Protocol.complete_initialize(protocol, raw_manifest),
         {:ok, manifest} <- Manifest.new(raw_manifest) do
      {:ok, protocol, handle, manifest}
    end
  end

  defp maybe_restore(protocol, transport, handle, context, opts) do
    state = Map.get(context, :state, Map.get(context, "state", %{}))

    if state == %{} do
      {:ok, protocol, handle}
    else
      id = "restore-1"

      with {:ok, frame, protocol} <- Protocol.request(protocol, id, "state.restore", %{"state" => state}),
           {:ok, line, handle} <- transport_exchange(transport, handle, frame, timeout(opts)),
           {:ok, %{"result" => _result}, protocol} <- Protocol.receive_line(protocol, line) do
        {:ok, protocol, handle}
      end
    end
  end

  defp transport_exchange(transport, handle, frame, timeout_ms),
    do: safe_transport(fn -> transport.exchange(handle, frame, timeout_ms) end)

  defp protocol_call(state, method, params, timeout, caller) do
    id = "call-#{state.next_id}"

    with :ok <- authorized_call(state.manifest, method, params),
         {:ok, frame, protocol} <- Protocol.request(state.protocol, id, method, params),
         {:ok, line, handle} <- exchange_monitored(state, id, frame, timeout, caller),
         {:ok, message, protocol} <- Protocol.receive_line(protocol, line),
         {:ok, result} <- response_result(message) do
      {:ok, result, %{state | protocol: protocol, handle: handle, next_id: state.next_id + 1}}
    else
      {:error, %Error{} = error} -> {:error, error, %{state | next_id: state.next_id + 1}}
      reason -> {:error, error(:process_extension_call_failed, reason, state), %{state | next_id: state.next_id + 1}}
    end
  end

  defp exchange_monitored(state, id, frame, timeout, caller) do
    owner = self()
    caller_monitor = Process.monitor(caller)

    {worker, worker_monitor} =
      spawn_monitor(fn ->
        result = safe_transport(fn -> state.transport.exchange(state.handle, frame, timeout) end)
        send(owner, {:process_extension_exchange, self(), result})
      end)

    receive do
      {:process_extension_exchange, ^worker, result} ->
        Process.demonitor(caller_monitor, [:flush])
        Process.demonitor(worker_monitor, [:flush])
        result

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        Process.demonitor(worker_monitor, [:flush])
        Process.exit(worker, :kill)
        _cancel = safe_transport(fn -> state.transport.cancel(state.handle, id) end)
        {:error, :process_extension_cancelled}

      {:DOWN, ^worker_monitor, :process, ^worker, reason} ->
        Process.demonitor(caller_monitor, [:flush])
        {:error, {:process_extension_transport_exit, reason}}
    after
      timeout ->
        Process.demonitor(worker_monitor, [:flush])
        Process.exit(worker, :kill)
        Process.demonitor(caller_monitor, [:flush])
        _cancel = safe_transport(fn -> state.transport.cancel(state.handle, id) end)
        {:error, {:process_extension_timeout, timeout}}
    end
  end

  defp response_result(%{"result" => result}), do: {:ok, result}
  defp response_result(%{"error" => error}), do: {:error, {:process_extension_remote_error, error}}

  defp build_slots(state) do
    %Manifest{} = manifest = state.manifest
    pid = self()

    Slot.new(%{
      namespace: state.binding.instance_key,
      tools: manifest.tools,
      tool_handlers: tool_handlers(pid, manifest.tools),
      commands: named_handlers(pid, "command.call", manifest.commands),
      providers: named_handlers(pid, "provider.start", manifest.providers),
      context: optional_handler(pid, manifest.context?, "context.contribute"),
      policy_advice: optional_handler(pid, manifest.policy_advice?, "policy.advise"),
      lifecycle: fn event -> notify(pid, "lifecycle.notify", %{"event" => Jidoka.Extension.Event.to_map(event)}) end,
      checkpoint: fn pid -> call(pid, "state.checkpoint", %{}) end,
      close: fn pid -> close(pid) end,
      state: manifest.state,
      result: manifest.result,
      ui_data: manifest.ui_data
    })
  end

  defp tool_handlers(pid, tools) do
    Map.new(tools, fn tool ->
      name = tool.name
      {name, fn arguments, _context -> call(pid, "tool.call", %{"name" => name, "arguments" => arguments}) end}
    end)
  end

  defp named_handlers(pid, method, names) do
    Map.new(names, fn name ->
      {name,
       fn input -> call(pid, method, %{"name" => name, "input" => input, "provider" => name, "request" => input}) end}
    end)
  end

  defp optional_handler(pid, enabled?, method) do
    if enabled?, do: fn _instance, input -> call(pid, method, %{"input" => input}) end
  end

  defp close_state(%{closed?: true} = state, _opts), do: {:ok, state}

  defp close_state(state, opts) do
    timeout = Keyword.get(opts, :timeout_ms, state.timeout_ms)
    protocol_result = protocol_call(state, "shutdown", %{}, timeout, self())

    close_handle =
      case protocol_result do
        {:ok, _result, protocol_state} -> protocol_state.handle
        _result -> state.handle
      end

    transport_result = safe_transport(fn -> state.transport.close(close_handle, opts) end)
    next = %{state | closed?: true, protocol: Protocol.close(state.protocol)}

    transport_ok? = transport_result == :ok or match?({:ok, _}, transport_result)

    if match?({:ok, _, _}, protocol_result) and transport_ok? do
      {:ok, next}
    else
      {{:error, error(:process_extension_cleanup_failed, {protocol_result, transport_result}, state)}, next}
    end
  end

  defp validate_launch(binding, mode, evidence) do
    enforced? = Map.get(evidence, :status, Map.get(evidence, "status")) in [:enforced, "enforced"]
    host_process? = "host_process" in binding.permissions.values

    cond do
      mode == :automation and not enforced? -> {:error, :constrained_launch_required}
      not enforced? and not host_process? -> {:error, :host_process_not_granted}
      true -> Contract.validate_safe_map(evidence)
    end
  end

  defp authorized_call(%Manifest{} = manifest, "tool.call", params),
    do: declared(Map.get(params, "name"), manifest.tool_names, :tool)

  defp authorized_call(%Manifest{} = manifest, "command.call", params),
    do: declared(Map.get(params, "name"), manifest.command_names, :command)

  defp authorized_call(%Manifest{} = manifest, "provider.start", params),
    do: declared(Map.get(params, "provider"), manifest.provider_names, :provider)

  defp authorized_call(_manifest, _method, _params), do: :ok

  defp declared(name, names, kind) do
    if MapSet.member?(names, name),
      do: :ok,
      else: {:error, {:undeclared_process_extension_capability, kind, name}}
  end

  defp transport_diagnostics(state) do
    diagnostics =
      if function_exported?(state.transport, :diagnostics, 1),
        do: state.transport.diagnostics(state.handle),
        else: %{}

    Contract.project(diagnostics)
  rescue
    _exception -> %{"status" => "unavailable"}
  end

  defp error(code, reason, state) do
    Error.new(code, %{
      extension_id: state.binding.request_id,
      reason: redact(reason),
      diagnostics: transport_diagnostics(state)
    })
  end

  defp safe_transport(function) do
    function.()
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout_ms, @default_timeout)
  defp redact(value), do: value |> Contract.project() |> inspect(limit: 20, printable_limit: 1_000)
end
