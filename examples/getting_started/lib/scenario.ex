defmodule JidokaExamples.GettingStarted.Scenario do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Schema
  alias Jidoka.Session
  alias JidokaExamples.GettingStarted.Agent

  @first_input "Remember that my team is called Platform."
  @second_input "What is my team called?"
  @first_answer "I will remember that your team is called Platform."
  @second_answer "Your team is called Platform."

  def run(opts \\ []) do
    first_input = Keyword.get(opts, :first_input, @first_input)
    second_input = Keyword.get(opts, :second_input, @second_input)
    observer = Keyword.get(opts, :observer)
    session_id = Keyword.get(opts, :session_id, "getting-started-session")
    model = deterministic_model(observer, first_input, second_input)

    with {:ok, preflight} <- Jidoka.preflight(Agent, first_input),
         {:ok, session} <- Session.start(Agent, session_id),
         {:ok, session, first_answer} <- Session.chat(session, first_input, llm: model),
         {:ok, session, second_answer} <- Session.chat(session, second_input, llm: model) do
      {:ok,
       %{
         agent_id: preflight.agent.id,
         answers: [first_answer, second_answer],
         diagnostics: preflight.diagnostics,
         inputs: [first_input, second_input],
         messages: Enum.map(preflight.prompt.messages, &Map.take(&1, [:content, :role])),
         model: preflight.prompt.model,
         operations: Enum.map(preflight.prompt.operations, & &1.name),
         session_id: session.session_id,
         turn_count: session.conversation.turn_count
       }}
    end
  end

  defp deterministic_model(observer, first_input, second_input) do
    fn %Effect.Intent{kind: :llm, payload: payload}, %Effect.Journal{}, _context ->
      messages = payload |> Schema.get_key(:prompt) |> Schema.get_key(:messages, [])
      notify(observer, {:getting_started_model_called, messages})

      answer =
        cond do
          message?(messages, second_input) -> @second_answer
          message?(messages, first_input) -> @first_answer
          true -> raise "unexpected Getting Started prompt"
        end

      {:ok, %{type: :final, content: answer}}
    end
  end

  defp message?(messages, content) do
    Enum.any?(messages, &(Schema.get_key(&1, :content) == content))
  end

  defp notify(observer, message) when is_pid(observer), do: send(observer, message)
  defp notify(_observer, _message), do: :ok
end
