Mix.Task.run("app.start")

defmodule JidokaExamples.FirstAgent.Assistant do
  use Jidoka.Agent

  agent :example_assistant do
    model :fast
    instructions "Answer clearly and concisely."
  end
end

alias JidokaExamples.FirstAgent.Assistant

session =
  Assistant
  |> Jidoka.session("user-123", context: %{actor_id: "user_123"})

chat_opts = Jidoka.Session.chat_opts(session)

IO.inspect(
  %{
    agent_id: Assistant.id(),
    instructions: Assistant.instructions(),
    runtime_module: Assistant.runtime_module(),
    session_id: session.id,
    conversation_id: chat_opts[:conversation],
    context: chat_opts[:context]
  },
  label: "first_agent"
)

IO.puts("Live turn shape: Jidoka.chat(session, \"Summarize this ticket.\")")
