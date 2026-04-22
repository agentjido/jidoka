defmodule Jidoka.CLI do
  @moduledoc false

  alias Jidoka.Hardening.EvaluationCommand
  alias Jidoka.PromptCommand
  alias Jidoka.RuntimeBootstrap

  @spec main([String.t()]) :: no_return()
  def main(args) do
    System.halt(run(args))
  end

  @spec run([String.t()]) :: 0 | 1
  def run(args) do
    case args do
      [] ->
        print_help()
        0

      ["help"] ->
        print_help()
        0

      ["version"] ->
        IO.puts(version())
        0

      ["eval-mvp"] ->
        run_eval_mvp()

      ["eval_mvp"] ->
        run_eval_mvp()

      ["prompt" | prompt_parts] ->
        run_prompt(prompt_parts)

      _ ->
        IO.puts(:stderr, "unknown command: #{Enum.join(args, " ")}")
        print_help(:stderr)
        1
    end
  end

  defp run_eval_mvp do
    with :ok <- RuntimeBootstrap.ensure_started() do
      case EvaluationCommand.run() do
        {:ok, _results} ->
          0

        {:error, reason, _results} ->
          IO.puts(:stderr, reason)
          1
      end
    else
      {:error, reason} ->
        IO.puts(:stderr, format_reason(reason))
        1
    end
  end

  defp run_prompt([]) do
    prompt =
      case IO.read(:stdio, :eof) do
        :eof -> ""
        contents -> IO.iodata_to_binary(contents)
      end
      |> String.trim()

    PromptCommand.run(prompt)
  end

  defp run_prompt(prompt_parts) do
    prompt_parts
    |> Enum.join(" ")
    |> PromptCommand.run()
  end

  defp version do
    :ok =
      case Application.load(:jidoka) do
        :ok -> :ok
        {:error, {:already_loaded, :jidoka}} -> :ok
      end

    :jidoka
    |> Application.spec(:vsn)
    |> to_string()
  end

  defp print_help(device \\ :stdio) do
    IO.puts(
      device,
      """
      Usage:
        jidoka help
        jidoka version
        jidoka eval-mvp
        jidoka prompt "summarize the current repo state"

      Commands:
        eval-mvp  Run the MVP evaluation fixture corpus.
        prompt    Execute a prompt with the Jido AI coding agent.
        version   Print the jidoka version.
        help      Print this message.
      """
    )
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
