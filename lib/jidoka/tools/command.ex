defmodule Jidoka.Tools.Command do
  @moduledoc false

  @default_timeout_ms 120_000
  @default_max_output_bytes 40_000

  @spec run(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, map()}
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_output_bytes = Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)
    cwd = Keyword.fetch!(opts, :cd)

    case System.find_executable(executable) do
      nil ->
        {:error, %{type: :executable_not_found, executable: executable}}

      executable_path ->
        execute(executable_path, args, cwd, timeout_ms, max_output_bytes)
    end
  end

  defp execute(executable_path, args, cwd, timeout_ms, max_output_bytes) do
    task =
      Task.async(fn ->
        System.cmd(executable_path, args,
          cd: cwd,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_status}} ->
        {:ok,
         %{
           args: [Path.basename(executable_path) | args],
           exit_status: exit_status,
           output: truncate(output, max_output_bytes)
         }}

      nil ->
        {:error, %{type: :command_timeout, timeout_ms: timeout_ms, args: args}}
    end
  end

  defp truncate(output, max_output_bytes) when byte_size(output) > max_output_bytes do
    binary_part(output, 0, max_output_bytes) <> "\n[output truncated]"
  end

  defp truncate(output, _max_output_bytes), do: output
end
