defmodule Jidoka.CodingPack.GitPort do
  @moduledoc "Trusted Git command binding that uses a constrained shell port."

  alias Jidoka.CodingPack.{Error, ShellPort, Workspace}

  @enforce_keys [:shell, :command]
  defstruct [:shell, :command]

  @type t :: %__MODULE__{shell: ShellPort.t(), command: String.t()}

  @doc "Builds a Git port from trusted host configuration."
  @spec new(ShellPort.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(%ShellPort{} = shell, opts \\ []) when is_list(opts) do
    command = Keyword.get(opts, :command, "git")

    if is_binary(command) and command != "",
      do: {:ok, %__MODULE__{shell: shell, command: command}},
      else: {:error, Error.new(:coding_git_registration_invalid)}
  end

  @doc false
  @spec run(t(), Workspace.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(%__MODULE__{} = port, %Workspace{} = workspace, args, opts \\ []) when is_list(args) do
    request = %{
      command: port.command,
      args: args,
      stdin: "",
      cwd: ".",
      timeout_ms: Keyword.get(opts, :timeout_ms, workspace.limits.max_shell_timeout_ms),
      max_output_bytes: Keyword.get(opts, :max_output_bytes, workspace.limits.max_shell_output_bytes),
      network: false
    }

    case ShellPort.execute(port.shell, workspace, request, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, %Error{code: :coding_shell_command_denied} = error} ->
        {:error, Error.new(:coding_git_unavailable, %{reason: error.details})}

      {:error, %Error{} = error} ->
        {:error, Error.new(:coding_git_environment_failed, %{reason: %{code: error.code, details: error.details}})}
    end
  end
end
