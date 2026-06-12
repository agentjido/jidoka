defmodule Jidoka.VerificationCommand do
  @moduledoc false

  alias Jidoka.Tools.Command

  @default_checks [:format, :compile, :test, :dialyzer]
  @check_args %{
    format: ["format", "--check-formatted"],
    compile: ["compile", "--warnings-as-errors"],
    test: ["test"],
    dialyzer: ["dialyzer"]
  }

  @type check :: :format | :compile | :test | :dialyzer

  @spec default_checks() :: [check()]
  def default_checks, do: @default_checks

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def run(workspace_path, opts \\ []) when is_binary(workspace_path) do
    checks = opts |> Keyword.get(:checks, @default_checks) |> normalize_checks()
    timeout_ms = Keyword.get(opts, :timeout_ms, 180_000)
    progress_fun = Keyword.get(opts, :progress_fun, fn _event, _metadata -> :ok end)

    steps =
      Enum.reduce_while(checks, [], fn check, acc ->
        progress_fun.(:verification_step_started, %{check: check})

        result = run_check(workspace_path, check, timeout_ms)

        progress_fun.(:verification_step_completed, %{
          check: check,
          exit_status: step_exit_status(result)
        })

        updated = acc ++ [step_result(check, result)]

        case result do
          {:ok, %{exit_status: 0}} -> {:cont, updated}
          _ -> {:halt, updated}
        end
      end)

    status =
      if Enum.all?(steps, &(&1.exit_status == 0)) do
        :passed
      else
        :failed
      end

    {:ok, %{status: status, checks: checks, steps: steps}}
  end

  defp run_check(workspace_path, check, timeout_ms) do
    Command.run("mix", Map.fetch!(@check_args, check),
      cd: workspace_path,
      timeout_ms: timeout_ms,
      max_output_bytes: 80_000
    )
  end

  defp normalize_checks(checks) when is_list(checks) do
    checks
    |> Enum.map(&normalize_check/1)
    |> Enum.filter(&(&1 in @default_checks))
    |> case do
      [] -> @default_checks
      normalized -> normalized
    end
  end

  defp normalize_checks(_), do: @default_checks

  defp normalize_check(check) when is_atom(check), do: check
  defp normalize_check("format"), do: :format
  defp normalize_check("compile"), do: :compile
  defp normalize_check("test"), do: :test
  defp normalize_check("dialyzer"), do: :dialyzer
  defp normalize_check(_), do: nil

  defp step_result(check, {:ok, result}) do
    %{
      check: check,
      exit_status: result.exit_status,
      output: result.output,
      args: result.args
    }
  end

  defp step_result(check, {:error, reason}) do
    %{
      check: check,
      exit_status: 1,
      output: inspect(reason),
      args: ["mix", Atom.to_string(check)]
    }
  end

  defp step_exit_status({:ok, %{exit_status: exit_status}}), do: exit_status
  defp step_exit_status({:error, _reason}), do: 1
end
