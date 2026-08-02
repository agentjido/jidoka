defmodule JidokaExamples.GettingStarted.Scenario do
  @moduledoc false

  alias Jidoka.Effect
  alias JidokaExamples.GettingStarted.Agent

  @input "What can you help me with?"
  @answer "I can explain Jidoka agents and help you build one."

  def run(opts \\ []) do
    input = Keyword.get(opts, :input, @input)
    observer = Keyword.get(opts, :observer)

    with {:ok, preflight} <- Jidoka.preflight(Agent, input),
         {:ok, answer} <- Jidoka.chat(Agent, input, llm: deterministic_model(observer)) do
      {:ok,
       %{
         agent_id: preflight.agent.id,
         answer: answer,
         diagnostics: preflight.diagnostics,
         input: input,
         messages: Enum.map(preflight.prompt.messages, &Map.take(&1, [:content, :role])),
         model: preflight.prompt.model,
         operations: Enum.map(preflight.prompt.operations, & &1.name)
       }}
    end
  end

  defp deterministic_model(observer) do
    fn %Effect.Intent{kind: :llm}, %Effect.Journal{}, _context ->
      notify(observer, :getting_started_model_called)
      {:ok, %{type: :final, content: @answer}}
    end
  end

  defp notify(observer, message) when is_pid(observer), do: send(observer, message)
  defp notify(_observer, _message), do: :ok
end
