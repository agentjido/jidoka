defmodule Jidoka.ChatCommand do
  @moduledoc false

  alias Jidoka.PromptCommand

  @spec run(keyword()) :: 0 | 1
  def run(opts \\ []) do
    state = %{
      turns: 0,
      permission_mode:
        Keyword.get(opts, :permission_mode) || System.get_env("JIDOKA_PERMISSION_MODE") ||
          :read_only,
      model: configured_model()
    }

    IO.puts("jidoka chat")
    IO.puts("type /help for commands, /quit to exit")

    loop(state)
  end

  defp loop(state) do
    case IO.gets("jidoka> ") do
      :eof ->
        0

      {:error, reason} ->
        IO.puts(:stderr, "input error: #{inspect(reason)}")
        1

      input ->
        input
        |> String.trim()
        |> handle_input(state)
    end
  end

  defp handle_input("", state), do: loop(state)

  defp handle_input("/quit", _state), do: 0
  defp handle_input("/exit", _state), do: 0

  defp handle_input("/help", state) do
    IO.puts("""
    Commands:
      /help    Show commands.
      /status  Show chat status.
      /model   Show configured model source.
      /quit    Exit chat.
    """)

    loop(state)
  end

  defp handle_input("/status", state) do
    IO.puts("turns=#{state.turns} permission_mode=#{state.permission_mode} cwd=#{File.cwd!()}")
    loop(state)
  end

  defp handle_input("/model", state) do
    IO.puts("model=#{state.model}")
    loop(state)
  end

  defp handle_input("/" <> command, state) do
    IO.puts(:stderr, "unknown command: /#{command}")
    loop(state)
  end

  defp handle_input(prompt, state) do
    _exit_code = PromptCommand.run(prompt, permission_mode: state.permission_mode)
    loop(%{state | turns: state.turns + 1})
  end

  defp configured_model do
    cond do
      model = System.get_env("JIDOKA_MODEL") -> model
      System.get_env("OPENAI_API_KEY") -> "openai:gpt-4.1-mini"
      System.get_env("ANTHROPIC_API_KEY") -> "anthropic:claude-3-5-haiku-latest"
      true -> "not_configured"
    end
  end
end
