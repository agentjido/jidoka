defmodule Jidoka.ExecutionEnvironment.Manager do
  @moduledoc """
  Policy-gated manager for the execution-environment lifecycle.

  The manager owns transient adapter handles and enforces exclusive acquisition.
  Bindings, checkpoints, and enforcement evidence remain portable data.
  """

  use GenServer

  alias Jidoka.ExecutionEnvironment.Binding
  alias Jidoka.ExecutionEnvironment.Checkpoint
  alias Jidoka.ExecutionEnvironment.Conformance
  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.ExecutionEnvironment.EnforcementEvidence
  alias Jidoka.ExecutionEnvironment.Error
  alias Jidoka.ExecutionEnvironment.Manager.Handle
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.Registration
  alias Jidoka.ExecutionEnvironment.Selection
  alias Jidoka.ExecutionEnvironment.Validator
  alias Jidoka.Policy.Gate
  alias Jidoka.Policy.Request, as: GateRequest
  alias Jidoka.Runtime.BoundedCall
  alias Jidoka.Runtime.Limits.Exceeded

  @type manager :: GenServer.server()

  @doc "Starts a lifecycle manager for one validated environment selection."
  @spec start_link(Selection.t(), Gate.capability(), keyword()) :: GenServer.on_start()
  def start_link(selection, policy, opts \\ [])

  def start_link(%Selection{} = selection, policy, opts) when is_function(policy, 2) do
    with {:ok, selection} <- Selection.validate(selection) do
      GenServer.start_link(__MODULE__, {selection, policy, opts})
    end
  end

  def start_link(_selection, _policy, _opts), do: {:error, :invalid_environment_selection}

  @doc "Opens or locates the durable environment for a profile request."
  @spec open(manager(), PolicyRequest.t(), keyword()) ::
          {:ok, Binding.t(), EnforcementEvidence.t()} | {:error, Error.t()}
  def open(manager, %PolicyRequest{} = request, opts \\ []),
    do: GenServer.call(manager, {:open, request, opts}, :infinity)

  @doc "Acquires exclusive transient use of one portable binding."
  @spec acquire(manager(), Binding.t(), keyword()) ::
          {:ok, Handle.t(), EnforcementEvidence.t()} | {:error, Error.t()}
  def acquire(manager, %Binding{} = binding, opts \\ []),
    do: GenServer.call(manager, {:acquire, binding, opts}, :infinity)

  @doc "Creates a portable checkpoint from one acquired handle."
  @spec checkpoint(manager(), Handle.t(), Binding.t(), keyword()) ::
          {:ok, Binding.t(), Checkpoint.t(), EnforcementEvidence.t()} | {:error, Error.t()}
  def checkpoint(manager, %Handle{} = handle, %Binding{} = binding, opts \\ []),
    do: GenServer.call(manager, {:checkpoint, handle, binding, opts}, :infinity)

  @doc "Restores a binding from an immutable checkpoint; identity may change."
  @spec restore(manager(), Binding.t(), Checkpoint.t(), keyword()) ::
          {:ok, Binding.t(), EnforcementEvidence.t()} | {:error, Error.t()}
  def restore(manager, %Binding{} = binding, %Checkpoint{} = checkpoint, opts \\ []),
    do: GenServer.call(manager, {:restore, binding, checkpoint, opts}, :infinity)

  @doc "Forks an inactive binding from a forkable immutable checkpoint."
  @spec fork(manager(), Binding.t(), Checkpoint.t(), keyword()) ::
          {:ok, Binding.t(), Checkpoint.t(), EnforcementEvidence.t()} | {:error, Error.t()}
  def fork(manager, %Binding{} = binding, %Checkpoint{} = checkpoint, opts \\ []),
    do: GenServer.call(manager, {:fork, binding, checkpoint, opts}, :infinity)

  @doc "Closes one transient handle while preserving durable environment state."
  @spec close(manager(), Handle.t(), keyword()) :: {:ok, EnforcementEvidence.t()} | {:error, Error.t()}
  def close(manager, %Handle{} = handle, opts \\ []),
    do: GenServer.call(manager, {:close, handle, opts}, :infinity)

  @doc "Destroys durable resources. Repeated cleanup returns the first evidence."
  @spec cleanup(manager(), Binding.t(), keyword()) ::
          {:ok, EnforcementEvidence.t()} | {:error, Error.t()}
  def cleanup(manager, %Binding{} = binding, opts \\ []),
    do: GenServer.call(manager, {:cleanup, binding, opts}, :infinity)

  @doc "Executes a portable request through an acquired environment handle."
  @spec execute(manager(), Handle.t(), map(), keyword()) ::
          {:ok, {map(), EnforcementEvidence.t()}} | {:error, Error.t()}
  def execute(manager, %Handle{} = handle, request, opts \\ []) when is_map(request),
    do: GenServer.call(manager, {:execute, handle, request, opts}, :infinity)

  @doc "Acquires a handle, runs a callback, and always closes the handle."
  @spec with_acquired(manager(), Binding.t(), (Handle.t() -> term()), keyword()) ::
          {:ok, term(), EnforcementEvidence.t()} | {:error, term()}
  def with_acquired(manager, %Binding{} = binding, function, opts \\ []) when is_function(function, 1) do
    with {:ok, handle, _evidence} <- acquire(manager, binding, opts) do
      result = safe_function(function, handle)
      close_result = close(manager, handle, opts)

      case {result, close_result} do
        {{:ok, value}, {:ok, evidence}} -> {:ok, value, evidence}
        {{:error, reason}, {:ok, _evidence}} -> {:error, reason}
        {{:error, reason}, {:error, close_error}} -> {:error, {:primary_and_close_failed, reason, close_error}}
        {{:ok, _value}, {:error, close_error}} -> {:error, close_error}
      end
    end
  end

  @impl true
  def init({%Selection{registration: %Registration{} = registration}, policy, opts}) do
    case Conformance.validate(registration.adapter) do
      :ok ->
        {:ok,
         %{
           registration: registration,
           policy: policy,
           opts: opts,
           handles: %{},
           acquired: %{},
           cleanup_evidence: %{}
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:open, request, opts}, _from, state) do
    registration = state.registration

    result =
      with :ok <- profile_matches(request, registration),
           :ok <- Validator.validate_profile(registration.profile, registration.capabilities, request),
           :ok <- authorize(state, "open", request.profile_id, opts),
           {:ok, binding, evidence} <-
             call_adapter(registration.adapter, :open, [registration.profile, request, call_opts(state, opts)]),
           {:ok, binding} <- normalize_binding(binding, registration),
           {:ok, evidence} <- normalize_evidence(evidence, registration) do
        {:ok, binding, evidence}
      end

    {:reply, normalize_error(result, :open), state}
  end

  def handle_call({:acquire, binding, opts}, _from, state) do
    result =
      with :ok <- binding_usable(binding, state, :acquire),
           :ok <- not_acquired(binding, state),
           :ok <- authorize(state, "acquire", binding.resource_ref, opts),
           {:ok, raw_handle, evidence} <-
             call_adapter(state.registration.adapter, :acquire, [binding, call_opts(state, opts)]),
           {:ok, evidence} <- normalize_evidence_with_close(evidence, raw_handle, state, opts) do
        token = make_ref()
        handle = Handle.new(self(), token)
        {:ok, handle, raw_handle, evidence}
      end

    case result do
      {:ok, handle, raw_handle, evidence} ->
        {_manager, token} = Handle.identity(handle)
        handles = Map.put(state.handles, token, %{raw: raw_handle, binding: binding})
        acquired = Map.put(state.acquired, binding.resource_ref, token)
        {:reply, {:ok, handle, evidence}, %{state | handles: handles, acquired: acquired}}

      error ->
        {:reply, normalize_error(error, :acquire), state}
    end
  end

  def handle_call({:checkpoint, handle, binding, opts}, _from, state) do
    result =
      with {:ok, entry} <- handle_entry(handle, binding, state),
           :ok <- authorize(state, "checkpoint", binding.resource_ref, opts),
           {:ok, updated, checkpoint, evidence} <-
             call_adapter(state.registration.adapter, :checkpoint, [entry.raw, binding, call_opts(state, opts)]),
           {:ok, updated} <- normalize_binding(updated, state.registration),
           {:ok, checkpoint} <- normalize_checkpoint(checkpoint, updated, state.registration),
           {:ok, evidence} <- normalize_evidence(evidence, state.registration) do
        {:ok, updated, checkpoint, evidence}
      end

    case result do
      {:ok, _binding, _checkpoint, _evidence} = success -> {:reply, success, state}
      error -> close_after_error(handle, error, state, opts, :checkpoint)
    end
  end

  def handle_call({:restore, binding, checkpoint, opts}, _from, state) do
    result =
      with :ok <- binding_usable(binding, state, :restore),
           :ok <- checkpoint_matches(binding, checkpoint),
           :ok <- authorize(state, "restore", binding.resource_ref, opts),
           {:ok, updated, evidence} <-
             call_adapter(state.registration.adapter, :restore, [binding, checkpoint, call_opts(state, opts)]),
           {:ok, updated} <- normalize_binding(updated, state.registration),
           {:ok, evidence} <- normalize_evidence(evidence, state.registration) do
        {:ok, updated, evidence}
      end

    {:reply, normalize_error(result, :restore), state}
  end

  def handle_call({:fork, binding, checkpoint, opts}, _from, state) do
    result =
      with :ok <- binding_usable(binding, state, :fork),
           :ok <- checkpoint_matches(binding, checkpoint),
           :ok <- fork_supported(checkpoint, state.registration),
           :ok <- authorize(state, "fork", binding.resource_ref, opts),
           {:ok, child, child_checkpoint, evidence} <-
             call_adapter(state.registration.adapter, :fork, [binding, checkpoint, call_opts(state, opts)]),
           {:ok, child} <- normalize_binding(child, state.registration),
           {:ok, child_checkpoint} <- normalize_checkpoint(child_checkpoint, child, state.registration),
           {:ok, evidence} <- normalize_evidence(evidence, state.registration) do
        {:ok, child, child_checkpoint, evidence}
      end

    {:reply, normalize_error(result, :fork), state}
  end

  def handle_call({:close, handle, opts}, _from, state) do
    opts = cleanup_opts(opts)

    with {:ok, token, entry} <- owned_handle(handle, state),
         :ok <- authorize(state, "close", entry.binding.resource_ref, opts),
         {:ok, evidence} <- call_adapter(state.registration.adapter, :close, [entry.raw, call_opts(state, opts)]),
         {:ok, evidence} <- normalize_evidence(evidence, state.registration) do
      state = drop_handle(state, token, entry.binding.resource_ref)
      {:reply, {:ok, evidence}, state}
    else
      error -> {:reply, normalize_error(error, :close), state}
    end
  end

  def handle_call({:cleanup, binding, opts}, _from, state) do
    opts = cleanup_opts(opts)

    case Map.fetch(state.cleanup_evidence, binding.resource_ref) do
      {:ok, evidence} ->
        {:reply, {:ok, evidence}, state}

      :error ->
        result =
          with :ok <- binding_usable(binding, state, :cleanup),
               :ok <- not_acquired(binding, state),
               :ok <- authorize(state, "cleanup", binding.resource_ref, opts),
               {:ok, evidence} <-
                 call_adapter(state.registration.adapter, :cleanup, [binding, call_opts(state, opts)]) do
            normalize_evidence(evidence, state.registration)
          end

        case result do
          {:ok, evidence} ->
            cache = Map.put(state.cleanup_evidence, binding.resource_ref, evidence)
            {:reply, {:ok, evidence}, %{state | cleanup_evidence: cache}}

          error ->
            {:reply, normalize_error(error, :cleanup), state}
        end
    end
  end

  def handle_call({:execute, handle, request, opts}, _from, state) do
    result =
      with {:ok, _token, entry} <- owned_handle(handle, state),
           :ok <- execute_supported(state.registration.adapter),
           :ok <- Contract.validate_safe_map(request),
           :ok <- authorize_execute(state, entry.binding.resource_ref, request, opts),
           {:ok, result, evidence} <-
             call_adapter(state.registration.adapter, :execute, [entry.raw, request, call_opts(state, opts)]),
           true <- is_map(result),
           :ok <- Contract.validate_safe_map(result),
           {:ok, evidence} <- normalize_evidence(evidence, state.registration) do
        {:ok, {result, evidence}}
      end

    {:reply, normalize_error(result, :execute), state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.handles, fn {_token, entry} ->
      _result = call_adapter(state.registration.adapter, :close, [entry.raw, state.opts])
    end)

    :ok
  end

  defp authorize(state, action, resource_ref, opts) do
    request =
      GateRequest.new!(
        effect_class: :execution_environment,
        action: action,
        resource: %{"resource_ref" => resource_ref},
        request_id: Keyword.get(opts, :request_id, "environment-#{action}")
      )

    case Gate.check(request, state.policy, call_opts(state, opts)) do
      {:ok, _decision} -> :ok
      {:error, reason} -> {:error, {:policy_denied, reason}}
    end
  end

  defp authorize_execute(state, resource_ref, request, opts) do
    resource = %{
      "resource_ref" => resource_ref,
      "command" => Map.get(request, "command"),
      "command_class" => Map.get(request, "command_class"),
      "cwd" => Map.get(request, "cwd"),
      "mutation" => Map.get(request, "mutation"),
      "network" => Map.get(request, "network")
    }

    gate_request =
      GateRequest.new!(
        effect_class: :execution_environment,
        action: "execute",
        resource: resource,
        request_id: Keyword.get(opts, :request_id, "environment-execute")
      )

    case Gate.check(gate_request, state.policy, call_opts(state, opts)) do
      {:ok, _decision} -> :ok
      {:error, reason} -> {:error, {:policy_denied, reason}}
    end
  end

  defp execute_supported(adapter) do
    if function_exported?(adapter, :execute, 3), do: :ok, else: {:error, :execute_unsupported}
  end

  defp profile_matches(%PolicyRequest{profile_id: id}, %Registration{profile: %{profile_id: id}}), do: :ok
  defp profile_matches(_request, _registration), do: {:error, :profile_request_mismatch}

  defp binding_usable(%Binding{state: state}, _manager_state, _operation) when state in [:cleaned, :acquired],
    do: {:error, {:invalid_binding_state, state}}

  defp binding_usable(%Binding{} = binding, state, _operation) do
    cond do
      binding.profile_digest != state.registration.profile.digest -> {:error, :binding_profile_mismatch}
      binding.adapter_id != state.registration.profile.adapter_id -> {:error, :binding_adapter_mismatch}
      Map.has_key?(state.cleanup_evidence, binding.resource_ref) -> {:error, :binding_cleaned}
      true -> :ok
    end
  end

  defp not_acquired(binding, state) do
    if Map.has_key?(state.acquired, binding.resource_ref), do: {:error, :binding_already_acquired}, else: :ok
  end

  defp checkpoint_matches(binding, checkpoint) do
    cond do
      checkpoint.profile_digest != binding.profile_digest -> {:error, :checkpoint_profile_mismatch}
      checkpoint.binding_revision != binding.revision -> {:error, :checkpoint_binding_revision_mismatch}
      true -> :ok
    end
  end

  defp fork_supported(%Checkpoint{forkable: true}, %Registration{capabilities: %{fork: true}}), do: :ok
  defp fork_supported(_checkpoint, _registration), do: {:error, :fork_unsupported}

  defp handle_entry(handle, binding, state) do
    with {:ok, _token, entry} <- owned_handle(handle, state),
         true <- entry.binding.resource_ref == binding.resource_ref do
      {:ok, entry}
    else
      false -> {:error, :handle_binding_mismatch}
      error -> error
    end
  end

  defp owned_handle(%Handle{} = handle, state) do
    case Handle.identity(handle) do
      {manager, token} when manager == self() ->
        case Map.fetch(state.handles, token) do
          {:ok, entry} -> {:ok, token, entry}
          :error -> {:error, :stale_environment_handle}
        end

      _identity ->
        {:error, :foreign_environment_handle}
    end
  end

  defp normalize_binding(%Binding{} = binding, registration), do: validate_binding(binding, registration)

  defp normalize_binding(binding, registration) do
    with {:ok, binding} <- Binding.new(binding), do: validate_binding(binding, registration)
  end

  defp validate_binding(binding, registration) do
    if binding.profile_digest == registration.profile.digest and
         binding.adapter_id == registration.profile.adapter_id do
      {:ok, binding}
    else
      {:error, :adapter_binding_identity_mismatch}
    end
  end

  defp normalize_checkpoint(%Checkpoint{} = checkpoint, binding, registration),
    do: validate_checkpoint(checkpoint, binding, registration)

  defp normalize_checkpoint(checkpoint, binding, registration) do
    with {:ok, checkpoint} <- Checkpoint.new(checkpoint),
         do: validate_checkpoint(checkpoint, binding, registration)
  end

  defp validate_checkpoint(checkpoint, binding, registration) do
    if checkpoint.profile_digest == registration.profile.digest and
         checkpoint.binding_revision == binding.revision do
      {:ok, checkpoint}
    else
      {:error, :adapter_checkpoint_identity_mismatch}
    end
  end

  defp normalize_evidence(%EnforcementEvidence{} = evidence, registration),
    do: validate_evidence(evidence, registration)

  defp normalize_evidence(evidence, registration) do
    with {:ok, evidence} <- EnforcementEvidence.new(evidence), do: validate_evidence(evidence, registration)
  end

  defp validate_evidence(evidence, registration) do
    case Validator.validate_evidence(registration.profile, evidence) do
      :ok -> {:ok, evidence}
      {:error, _error} = error -> error
    end
  end

  defp normalize_evidence_with_close(evidence, raw_handle, state, opts) do
    case normalize_evidence(evidence, state.registration) do
      {:ok, evidence} ->
        {:ok, evidence}

      {:error, reason} ->
        close_result =
          call_adapter(state.registration.adapter, :close, [raw_handle, call_opts(state, cleanup_opts(opts))])

        {:error, {:invalid_acquire_evidence, reason, close_result}}
    end
  end

  defp close_after_error(handle, error, state, opts, operation) do
    case owned_handle(handle, state) do
      {:ok, token, entry} ->
        close_result =
          call_adapter(state.registration.adapter, :close, [entry.raw, call_opts(state, cleanup_opts(opts))])

        state = drop_handle(state, token, entry.binding.resource_ref)
        reason = {:lifecycle_failed_and_handle_closed, operation, error, close_result}
        {:reply, normalize_error({:error, reason}, operation), state}

      {:error, _reason} ->
        {:reply, normalize_error(error, operation), state}
    end
  end

  defp drop_handle(state, token, resource_ref) do
    %{state | handles: Map.delete(state.handles, token), acquired: Map.delete(state.acquired, resource_ref)}
  end

  defp call_adapter(adapter, function, arguments) do
    opts = List.last(arguments)

    BoundedCall.run(
      fn -> apply(adapter, function, arguments) end,
      :execution_environment,
      if(is_list(opts), do: opts, else: [])
    )
  end

  defp call_opts(state, opts), do: Keyword.merge(state.opts, opts)
  defp cleanup_opts(opts), do: Keyword.delete(opts, :cancellation)

  defp normalize_error({:error, %Error{} = error}, _operation), do: {:error, error}

  defp normalize_error(
         {:error, {:runtime_limit_exceeded, %Exceeded{} = exceeded}},
         operation
       ) do
    {:error,
     Error.new(:execution_environment_limit_exceeded, "execution environment call exceeded its limit", %{
       operation: operation,
       limit: exceeded
     })}
  end

  defp normalize_error({:error, reason}, operation) do
    {:error,
     Error.new(:execution_environment_lifecycle_failed, "execution environment lifecycle failed", %{
       operation: operation,
       reason: inspect(reason)
     })}
  end

  defp normalize_error(result, _operation), do: result

  defp safe_function(function, handle) do
    {:ok, function.(handle)}
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
