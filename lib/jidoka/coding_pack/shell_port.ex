defmodule Jidoka.CodingPack.ShellPort do
  @moduledoc "Trusted command registry and execution-environment port for coding shell requests."

  alias Jidoka.Cancellation
  alias Jidoka.CodingPack.{Error, Workspace}
  alias Jidoka.ExecutionEnvironment
  alias Jidoka.ExecutionEnvironment.{Binding, EnforcementEvidence, Manager, SecurityProfile}

  @command_keys [:class, :mutation, :network]
  @mutations ["read", "write"]

  @enforce_keys [:manager, :binding, :profile, :commands, :opts]
  defstruct [:manager, :binding, :profile, :commands, opts: []]

  @type command :: %{
          required(:class) => String.t(),
          required(:mutation) => String.t(),
          required(:network) => boolean()
        }
  @type t :: %__MODULE__{
          manager: GenServer.server(),
          binding: Binding.t(),
          profile: SecurityProfile.t(),
          commands: %{required(String.t()) => command()},
          opts: keyword()
        }

  @doc "Builds a shell port from trusted host configuration."
  @spec new(GenServer.server(), Binding.t(), SecurityProfile.t(), map(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(manager, %Binding{} = binding, %SecurityProfile{} = profile, commands, opts \\ [])
      when is_map(commands) and is_list(opts) do
    with true <- binding.profile_id == profile.profile_id,
         true <- binding.profile_digest == profile.digest,
         {:ok, commands} <- commands(commands) do
      {:ok,
       %__MODULE__{
         manager: manager,
         binding: binding,
         profile: profile,
         commands: commands,
         opts: opts
       }}
    else
      false -> {:error, Error.new(:coding_shell_binding_mismatch)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @doc "Runs one normalized command through an acquired environment and always closes it."
  @spec execute(t(), Workspace.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def execute(%__MODULE__{} = port, %Workspace{} = workspace, request, opts \\ [])
      when is_map(request) and is_list(opts) do
    with true <- Workspace.permits?(workspace, :shell),
         {:ok, command} <- fetch_command(port, request.command),
         :ok <- network(command, request.network),
         :ok <- cancellation(opts),
         request = Map.merge(request, command),
         {:ok, {result, evidence}, cleanup} <- execute_acquired(port, request, opts),
         {:ok, result} <- normalize_result(result, request),
         :ok <- shell_evidence(evidence, request) do
      {:ok,
       Map.merge(result, %{
         "backend" => evidence.backend,
         "enforcement" => EnforcementEvidence.to_map(evidence),
         "cleanup" => EnforcementEvidence.to_map(cleanup)
       })}
    else
      false ->
        {:error, Error.new(:coding_shell_denied, %{reason: :workspace_access})}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, %ExecutionEnvironment.Error{} = error} ->
        {:error, Error.new(:coding_shell_environment_failed, %{reason: ExecutionEnvironment.Error.to_map(error)})}

      {:error, reason} ->
        {:error, Error.new(:coding_shell_environment_failed, %{reason: inspect(reason)})}
    end
  end

  defp execute_acquired(port, request, opts) do
    call_opts = Keyword.merge(port.opts, opts)

    callback = fn handle ->
      case Manager.execute(port.manager, handle, portable_request(request), call_opts) do
        {:ok, {result, evidence}} -> {:shell_execute_ok, result, evidence}
        {:error, error} -> {:shell_execute_error, error}
      end
    end

    case Manager.with_acquired(port.manager, port.binding, callback, call_opts) do
      {:ok, {:shell_execute_ok, result, evidence}, cleanup} -> {:ok, {result, evidence}, cleanup}
      {:ok, {:shell_execute_error, error}, _cleanup} -> {:error, error}
      other -> other
    end
  end

  defp commands(commands) do
    Enum.reduce_while(commands, {:ok, %{}}, fn {name, attrs}, {:ok, normalized} ->
      case normalize_command_registration(name, attrs) do
        {:ok, name, command} -> {:cont, {:ok, Map.put(normalized, name, command)}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_command_registration(name, attrs)
       when is_binary(name) and name != "" and (is_map(attrs) or is_list(attrs)) do
    attrs = Jidoka.Schema.normalize_attrs(attrs)
    unknown = Map.keys(attrs) -- @command_keys
    class = Map.get(attrs, :class)
    mutation = Map.get(attrs, :mutation, "read") |> to_string()
    network = Map.get(attrs, :network, false)

    if unknown == [] and is_binary(class) and class != "" and mutation in @mutations and is_boolean(network),
      do: {:ok, name, %{command_class: class, mutation: mutation, network_allowed: network}},
      else: {:error, Error.new(:coding_shell_command_registration_invalid, %{command: name})}
  end

  defp normalize_command_registration(name, _attrs),
    do: {:error, Error.new(:coding_shell_command_registration_invalid, %{command: inspect(name)})}

  defp fetch_command(port, name) do
    case Map.fetch(port.commands, name) do
      {:ok, command} -> {:ok, command}
      :error -> {:error, Error.new(:coding_shell_command_denied, %{command: name})}
    end
  end

  defp network(%{network_allowed: true}, _requested), do: :ok
  defp network(%{network_allowed: false}, false), do: :ok
  defp network(_command, true), do: {:error, Error.new(:coding_shell_network_denied)}

  defp normalize_result(result, request) when is_map(result) do
    result = stringify_keys(result)
    status = Map.get(result, "status")
    stdout = Map.get(result, "stdout", "")
    stderr = Map.get(result, "stderr", "")
    exit_status = Map.get(result, "exit_status")
    duration_ms = Map.get(result, "duration_ms", 0)

    with {:ok, status} <- status(status, exit_status),
         true <- text?(stdout) and text?(stderr),
         true <- is_integer(duration_ms) and duration_ms >= 0 do
      {stdout, stdout_truncated} = cap(stdout, request.max_output_bytes)
      {stderr, stderr_truncated} = cap(stderr, request.max_output_bytes)

      {:ok,
       %{
         "status" => status,
         "stdout" => stdout,
         "stderr" => stderr,
         "exit_status" => exit_status,
         "duration_ms" => duration_ms,
         "stdout_truncated" => stdout_truncated or truthy?(result["stdout_truncated"]),
         "stderr_truncated" => stderr_truncated or truthy?(result["stderr_truncated"])
       }}
    else
      _reason -> {:error, Error.new(:coding_shell_result_invalid)}
    end
  end

  defp normalize_result(_result, _request), do: {:error, Error.new(:coding_shell_result_invalid)}

  defp status(value, exit_status) when value in [:ok, "ok"] and exit_status == 0, do: {:ok, "ok"}

  defp status(value, exit_status)
       when value in [:nonzero, "nonzero"] and is_integer(exit_status) and exit_status != 0,
       do: {:ok, "nonzero"}

  defp status(value, exit_status)
       when value in [:timeout, "timeout", :cancelled, "cancelled", :blocked, "blocked", :error, "error"] and
              (is_nil(exit_status) or is_integer(exit_status)),
       do: {:ok, to_string(value)}

  defp status(_value, _exit_status), do: {:error, :invalid_status}

  defp shell_evidence(evidence, request) do
    facts = evidence.facts

    checks = [
      evidence.status == :confirmed,
      fact(facts, "shell_execute") == true,
      fact(facts, "cwd_confined") == true,
      fact(facts, "wall_timeout") == true,
      fact(facts, "output_limit") == true,
      fact(facts, "cancellation") == true,
      fact(facts, "command_class") == request.command_class,
      limit_satisfied?(evidence.applied_limits, "wall_time_ms", request.timeout_ms),
      limit_satisfied?(evidence.applied_limits, "output_bytes", request.max_output_bytes),
      not request.network or evidence.network in [:restricted, :unrestricted]
    ]

    if Enum.all?(checks),
      do: :ok,
      else: {:error, Error.new(:coding_shell_enforcement_unconfirmed)}
  end

  defp portable_request(request) do
    %{
      "command" => request.command,
      "args" => request.args,
      "stdin" => request.stdin,
      "cwd" => request.cwd,
      "timeout_ms" => request.timeout_ms,
      "max_output_bytes" => request.max_output_bytes,
      "network" => request.network,
      "command_class" => request.command_class,
      "mutation" => request.mutation
    }
  end

  defp cancellation(opts) do
    case Cancellation.check(opts) do
      :ok -> :ok
      {:error, :cancelled} -> {:error, Error.new(:coding_shell_cancelled)}
    end
  end

  defp fact(facts, key), do: Map.get(facts, key, Map.get(facts, known_atom(key)))
  defp known_atom("shell_execute"), do: :shell_execute
  defp known_atom("cwd_confined"), do: :cwd_confined
  defp known_atom("wall_timeout"), do: :wall_timeout
  defp known_atom("output_limit"), do: :output_limit
  defp known_atom("cancellation"), do: :cancellation
  defp known_atom("command_class"), do: :command_class

  defp limit_satisfied?(limits, key, ceiling) do
    case Map.get(limits, key, Map.get(limits, known_limit_atom(key))) do
      value when is_integer(value) and value > 0 -> value <= ceiling
      _value -> false
    end
  end

  defp known_limit_atom("wall_time_ms"), do: :wall_time_ms
  defp known_limit_atom("output_bytes"), do: :output_bytes

  defp text?(value), do: is_binary(value) and String.valid?(value)
  defp truthy?(true), do: true
  defp truthy?(_value), do: false
  defp cap(value, limit) when byte_size(value) <= limit, do: {value, false}
  defp cap(value, limit), do: {utf8_prefix(value, limit), true}

  defp utf8_prefix(value, limit) do
    candidate = binary_part(value, 0, limit)
    if String.valid?(candidate), do: candidate, else: utf8_prefix(value, limit - 1)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
