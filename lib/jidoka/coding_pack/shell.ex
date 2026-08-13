defmodule Jidoka.CodingPack.Shell do
  @moduledoc "Bounded shell requests that run only through a trusted execution environment."

  alias Jidoka.CodingPack.{Error, ShellPort, Workspace}
  alias Jidoka.Effect.OperationRequest

  @keys ~w(command args stdin cwd timeout_ms max_output_bytes network)

  @doc "Returns the model-visible shell operation and its constrained handler."
  @spec tool(Workspace.t(), ShellPort.t()) ::
          %{operation: Jidoka.Agent.Spec.Operation.t(), handler: function()}
  def tool(%Workspace{} = workspace, %ShellPort{} = port) do
    %{
      operation:
        Jidoka.Agent.Spec.Operation.new!(
          name: "coding.shell",
          description: "Run one registered command in a constrained execution environment.",
          idempotency: :reconcile,
          metadata: %{
            "kind" => "tool",
            "source" => "coding_pack",
            "parameters_schema" => input_schema(workspace),
            "policy_resource" => %{
              "kind" => "coding_workspace",
              "access" => "shell",
              "argument_fields" => ["command", "args", "cwd", "timeout_ms", "max_output_bytes", "network"]
            }
          }
        ),
      handler: fn intent, _journal, context ->
        with {:ok, request} <- OperationRequest.from_input(intent.payload) do
          run(workspace, port, request.arguments,
            request_id: intent.id,
            cancellation: Jidoka.Context.get_runtime(context, :cancellation)
          )
        end
      end
    }
  end

  defp input_schema(workspace) do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string", "minLength" => 1},
        "args" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "maxItems" => workspace.limits.max_shell_args
        },
        "stdin" => %{"type" => "string"},
        "cwd" => %{"type" => "string", "minLength" => 1},
        "timeout_ms" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => workspace.limits.max_shell_timeout_ms
        },
        "max_output_bytes" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => workspace.limits.max_shell_output_bytes
        },
        "network" => %{"type" => "boolean"}
      },
      "required" => ["command"],
      "additionalProperties" => false
    }
  end

  @doc "Validates and runs one bounded command request."
  @spec run(Workspace.t(), ShellPort.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(workspace, port, arguments, opts \\ [])

  def run(%Workspace{} = workspace, %ShellPort{} = port, arguments, opts)
      when is_map(arguments) and is_list(opts) do
    with {:ok, request} <- input(arguments, workspace),
         {:ok, cwd} <- Workspace.resolve(workspace, request.cwd, type: :directory) do
      ShellPort.execute(port, workspace, %{request | cwd: cwd.relative}, opts)
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def run(%Workspace{}, %ShellPort{}, _arguments, _opts),
    do: {:error, Error.new(:coding_shell_input_invalid)}

  defp input(arguments, workspace) do
    arguments = stringify_keys(arguments)
    unknown = Map.keys(arguments) -- @keys
    command = Map.get(arguments, "command")
    args = Map.get(arguments, "args", [])
    stdin = Map.get(arguments, "stdin", "")
    cwd = Map.get(arguments, "cwd", ".")
    timeout = Map.get(arguments, "timeout_ms", workspace.limits.max_shell_timeout_ms)
    output = Map.get(arguments, "max_output_bytes", workspace.limits.max_shell_output_bytes)
    network = Map.get(arguments, "network", false)

    with [] <- unknown,
         true <- safe_text?(command) and command != "",
         true <- args?(args, workspace.limits.max_shell_args),
         true <- safe_text?(stdin) and byte_size(stdin) <= workspace.limits.max_shell_stdin_bytes,
         true <- safe_text?(cwd) and cwd != "",
         true <- ceiling?(timeout, workspace.limits.max_shell_timeout_ms),
         true <- ceiling?(output, workspace.limits.max_shell_output_bytes),
         true <- is_boolean(network) do
      {:ok,
       %{
         command: command,
         args: args,
         stdin: stdin,
         cwd: cwd,
         timeout_ms: timeout,
         max_output_bytes: output,
         network: network
       }}
    else
      reason -> {:error, Error.new(:coding_shell_input_invalid, %{reason: inspect(reason)})}
    end
  end

  defp args?(args, limit),
    do: is_list(args) and length(args) <= limit and Enum.all?(args, &safe_text?/1)

  defp ceiling?(value, ceiling), do: is_integer(value) and value > 0 and value <= ceiling
  defp safe_text?(value), do: is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>)
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
