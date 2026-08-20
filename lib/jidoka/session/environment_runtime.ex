defmodule Jidoka.Session.EnvironmentRuntime do
  @moduledoc """
  Coordinates transient environment resources for session execution.

  Session callers normally use `Jidoka.Session`. This module keeps manager
  processes and acquired handles in runtime options and returns only portable
  `Jidoka.Session.Environment` data.
  """

  alias Jidoka.ExecutionEnvironment.Manager
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.Selection
  alias Jidoka.Session.Data
  alias Jidoka.Session.Environment

  @type lease :: %{manager: Manager.manager(), handle: Manager.Handle.t(), tracker: pid()}

  @doc "Owns one manager for a resolved registration during a public run."
  @spec with_manager(keyword(), (keyword() -> term())) :: term()
  def with_manager(opts, function) when is_list(opts) and is_function(function, 1) do
    case unresolved_selection(opts) do
      :none ->
        function.(opts)

      {:ok, selection} ->
        with {:ok, policy} <- environment_policy(opts),
             {:ok, manager_opts} <- manager_opts(opts),
             {:ok, manager} <- Manager.start_link(selection, policy, manager_opts) do
          run_with_manager(manager, selection, manager_opts, opts, function)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp run_with_manager(manager, selection, manager_opts, opts, function) do
    registration = Selection.registration(selection)

    runtime = %{
      manager: manager,
      request: Selection.request(selection),
      retention: registration.profile.retention,
      opts: manager_opts
    }

    try do
      function.(Keyword.put(opts, :execution_environment, runtime))
    after
      if Process.alive?(manager), do: GenServer.stop(manager, :normal)
    end
  end

  @doc "Opens configured environment state when the session has no binding."
  @spec prepare(Data.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}
  def prepare(%Data{environment: nil} = session, opts) do
    case config(opts) do
      :none ->
        {:ok, session}

      {:ok, manager, request, retention} ->
        with {:ok, binding, evidence} <- Manager.open(manager, request, lifecycle_opts(opts)) do
          {:ok, Data.put_environment(session, Environment.opened(request, binding, evidence, retention))}
        end

      {:error, _reason} = error ->
        error
    end
  end

  def prepare(%Data{environment: %Environment{} = environment} = session, opts) do
    with :ok <- Environment.ensure_usable(environment),
         :ok <- validate_runtime_profile(environment, opts) do
      {:ok, session}
    end
  end

  @doc "Acquires a transient handle and adds it to runtime options."
  @spec acquire(Data.t(), keyword()) ::
          {:ok, Data.t(), keyword(), lease() | nil} | {:error, term()}
  def acquire(%Data{environment: nil} = session, opts), do: {:ok, session, opts, nil}

  def acquire(%Data{environment: %Environment{} = environment} = session, opts) do
    with :ok <- Environment.ensure_usable(environment),
         {:ok, manager, _request, _retention} <- require_config(opts),
         {:ok, handle, evidence} <- Manager.acquire(manager, environment.binding, lifecycle_opts(opts)),
         environment = Environment.observed(environment, evidence),
         {:ok, tracker} <- Agent.start_link(fn -> environment end) do
      runtime_opts =
        opts
        |> Keyword.put(:execution_environment_handle, handle)
        |> Keyword.put(:execution_environment_manager, manager)
        |> Keyword.put(:execution_environment_tracker, tracker)
        |> put_capability_context(manager, handle, environment)

      {:ok, Data.put_environment(session, environment), runtime_opts,
       %{manager: manager, handle: handle, tracker: tracker}}
    end
  end

  @doc "Creates a portable environment checkpoint for the active handle."
  @spec checkpoint(keyword()) :: {:ok, Environment.t() | nil} | {:error, term()}
  def checkpoint(opts) do
    case runtime_refs(opts) do
      :none ->
        {:ok, nil}

      {:ok, manager, handle, tracker} ->
        checkpoint_tracked_environment(manager, handle, tracker, opts)
    end
  end

  @doc "Closes the active handle and applies the configured retention rule."
  @spec finish(lease() | nil, atom(), keyword()) ::
          {:ok, Environment.t() | nil}
          | {:error, Environment.t(), term()}
          | {:error, term()}
  def finish(nil, _terminal, _opts), do: {:ok, nil}

  def finish(%{manager: manager, handle: handle, tracker: tracker}, terminal, opts) do
    environment = Agent.get(tracker, & &1)
    close_result = Manager.close(manager, handle, lifecycle_opts(opts))

    result =
      case close_result do
        {:ok, close_evidence} ->
          closed = Environment.observed(environment, close_evidence)

          case maybe_cleanup(manager, closed, terminal, opts) do
            {:ok, final} = success ->
              notify_observer(final, opts)
              success

            {:error, _reason} = error ->
              notify_observer(closed, opts)
              {:error, reason} = error
              {:error, closed, reason}
          end

        {:error, _reason} = error ->
          notify_observer(environment, opts)
          {:error, reason} = error
          {:error, environment, reason}
      end

    Agent.stop(tracker)
    result
  end

  defp notify_observer(environment, opts) do
    case Keyword.get(opts, :session_environment_observer) do
      observer when is_function(observer, 1) -> observer.(environment)
      _observer -> :ok
    end
  end

  @doc "Restores the latest stored checkpoint before recovery work starts."
  @spec restore(Data.t(), keyword()) :: {:ok, Data.t()} | {:error, term()}
  def restore(%Data{environment: nil} = session, _opts), do: {:ok, session}

  def restore(%Data{environment: %Environment{checkpoint: nil}} = session, _opts),
    do: {:ok, session}

  def restore(%Data{environment: %Environment{} = environment} = session, opts) do
    with :ok <- Environment.ensure_usable(environment),
         {:ok, manager, _request, _retention} <- require_config(opts),
         {:ok, binding, evidence} <-
           Manager.restore(manager, environment.binding, environment.checkpoint, lifecycle_opts(opts)) do
      {:ok, Data.put_environment(session, Environment.restored(environment, binding, evidence))}
    end
  end

  @doc "Forks an immutable environment checkpoint for a child session."
  @spec fork(Data.t(), keyword()) :: {:ok, Environment.t() | nil} | {:error, term()}
  def fork(%Data{environment: nil}, _opts), do: {:ok, nil}

  def fork(%Data{environment: %Environment{checkpoint: nil}}, _opts),
    do: {:error, :execution_environment_fork_requires_checkpoint}

  def fork(%Data{environment: %Environment{} = environment}, opts) do
    with :ok <- Environment.ensure_usable(environment),
         {:ok, manager, _request, _retention} <- require_config(opts),
         {:ok, binding, checkpoint, evidence} <-
           Manager.fork(manager, environment.binding, environment.checkpoint, lifecycle_opts(opts)) do
      {:ok, Environment.forked(environment, binding, checkpoint, evidence)}
    end
  end

  defp maybe_cleanup(manager, %Environment{retention: :ephemeral} = environment, terminal, opts)
       when terminal in [:completed, :error, :cancelled] do
    with {:ok, evidence} <- Manager.cleanup(manager, environment.binding, lifecycle_opts(opts)) do
      {:ok, Environment.cleaned(environment, evidence)}
    end
  end

  defp maybe_cleanup(_manager, %Environment{} = environment, _terminal, _opts),
    do: {:ok, environment}

  defp checkpoint_tracked_environment(manager, handle, tracker, opts) do
    environment = Agent.get(tracker, & &1)

    case Manager.checkpoint(manager, handle, environment.binding, lifecycle_opts(opts)) do
      {:ok, binding, checkpoint, evidence} ->
        environment = Environment.checkpointed(environment, binding, checkpoint, evidence)
        Agent.update(tracker, fn _current -> environment end)
        {:ok, environment}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_runtime_profile(environment, opts) do
    case config(opts) do
      :none ->
        :ok

      {:ok, _manager, request, _retention} when request.profile_id == environment.request.profile_id ->
        :ok

      {:ok, _manager, request, _retention} ->
        {:error, {:execution_environment_profile_mismatch, environment.request.profile_id, request.profile_id}}

      {:error, _reason} = error ->
        error
    end
  end

  defp config(opts) do
    case Keyword.get(opts, :execution_environment) do
      nil -> :none
      config -> normalize_config(config)
    end
  end

  defp require_config(opts) do
    case config(opts) do
      {:ok, _manager, _request, _retention} = config -> config
      :none -> {:error, :missing_execution_environment_runtime}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_config(config) when is_list(config), do: normalize_config(Map.new(config))

  defp normalize_config(%{} = config) do
    manager = Map.get(config, :manager, Map.get(config, "manager"))
    request = Map.get(config, :request, Map.get(config, "request"))
    retention = Map.get(config, :retention, Map.get(config, "retention", :ephemeral))

    cond do
      is_nil(manager) -> {:error, :missing_execution_environment_manager}
      not match?(%PolicyRequest{}, request) -> {:error, {:invalid_execution_environment_request, request}}
      retention not in [:ephemeral, :durable] -> {:error, {:invalid_execution_environment_retention, retention}}
      true -> {:ok, manager, request, retention}
    end
  end

  defp normalize_config(config), do: {:error, {:invalid_execution_environment_runtime, config}}

  defp unresolved_selection(opts) do
    case Keyword.get(opts, :execution_environment) do
      nil ->
        :none

      config when is_list(config) ->
        unresolved_selection_config(Map.new(config))

      %{} = config ->
        case Selection.validate(config) do
          {:ok, selection} ->
            {:ok, selection}

          {:error, reason} ->
            invalid_selection(config, reason)
        end

      config ->
        {:error, {:invalid_execution_environment_runtime, config}}
    end
  end

  defp invalid_selection(%Selection{}, reason), do: {:error, reason}
  defp invalid_selection(config, _reason), do: unresolved_selection_config(config)

  defp unresolved_selection_config(config) do
    selection = Map.get(config, :selection, Map.get(config, "selection"))
    manager = Map.get(config, :manager, Map.get(config, "manager"))

    if is_nil(manager) do
      case Selection.validate(selection) do
        {:ok, selection} -> {:ok, selection}
        {:error, _reason} -> {:error, {:invalid_environment_selection, selection}}
      end
    else
      :none
    end
  end

  defp environment_policy(opts) do
    case Keyword.get(opts, :execution_environment_policy) do
      policy when is_function(policy, 2) -> {:ok, policy}
      nil -> {:error, :missing_execution_environment_policy}
      policy -> {:error, {:invalid_execution_environment_policy, policy}}
    end
  end

  defp manager_opts(opts) do
    case Keyword.get(opts, :execution_environment_adapter_opts, []) do
      manager_opts when is_list(manager_opts) ->
        if Keyword.keyword?(manager_opts),
          do: {:ok, manager_opts},
          else: {:error, {:invalid_execution_environment_adapter_opts, manager_opts}}

      manager_opts ->
        {:error, {:invalid_execution_environment_adapter_opts, manager_opts}}
    end
  end

  defp runtime_refs(opts) do
    with {:ok, manager} <- Keyword.fetch(opts, :execution_environment_manager),
         {:ok, handle} <- Keyword.fetch(opts, :execution_environment_handle),
         {:ok, tracker} <- Keyword.fetch(opts, :execution_environment_tracker) do
      {:ok, manager, handle, tracker}
    else
      :error -> :none
    end
  end

  defp lifecycle_opts(opts) do
    opts
    |> Keyword.get(:execution_environment)
    |> case do
      config when is_list(config) -> Keyword.get(config, :opts, [])
      %{} = config -> Map.get(config, :opts, Map.get(config, "opts", []))
      _config -> []
    end
    |> Keyword.merge(
      Keyword.take(opts, [
        :request_id,
        :session_id,
        :cancellation,
        :cancellation_poll_interval_ms,
        :runtime_limits,
        :runtime_sequence_started_at_ms,
        :clock
      ])
    )
  end

  defp put_capability_context(opts, manager, handle, environment) do
    runtime = %{
      manager: manager,
      handle: handle,
      binding: environment.binding,
      enforcement: environment.evidence
    }

    opts
    |> put_context_value(:llm_context, runtime)
    |> put_context_value(:operation_context, runtime)
  end

  defp put_context_value(opts, key, runtime) do
    current =
      opts
      |> Keyword.get(key, %{})
      |> Jidoka.Schema.normalize_attrs()

    Keyword.put(opts, key, Map.put(current, :execution_environment, runtime))
  end
end
