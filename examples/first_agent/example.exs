defmodule JidokaExamples.FirstAgent do
  @behaviour JidokaExamples.Example

  alias JidokaExamples.FirstAgent.Assistant

  @impl true
  def name, do: :first_agent

  @impl true
  def title, do: "First Agent"

  @impl true
  def features, do: [:agent, :model, :instructions, :session, :prompt_preflight]

  @impl true
  def summary, do: "Defines a minimal agent, creates a session, and previews the provider prompt."

  @impl true
  def run(opts \\ []) do
    case JidokaExamples.mode(opts) do
      :live -> run_live(opts)
      :verify -> run_verify(opts)
    end
  end

  defp run_verify(opts) do
    prompt = JidokaExamples.prompt(opts, "Explain what Jidoka adds on top of Jido in one sentence.")
    session = Jidoka.session(Assistant, "example-user", context: %{actor_id: "user_123"})
    {:ok, preflight} = Assistant.prompt_preflight(prompt, context: Jidoka.Session.chat_opts(session)[:context])

    {:ok,
     %{
       example: name(),
       mode: :verify,
       agent_id: Assistant.id(),
       runtime_module: inspect(Assistant.runtime_module()),
       session_id: session.id,
       conversation_id: session.conversation_id,
       prompt_sections: Enum.map(preflight.sections, & &1.name),
       system_prompt: preflight.system_prompt
     }}
  end

  defp run_live(opts) do
    with {:ok, provider_env} <- JidokaExamples.require_live_provider(opts) do
      prompt = JidokaExamples.prompt(opts, "Explain what Jidoka adds on top of Jido in one sentence.")
      session = Jidoka.session(Assistant, "example-live-user", context: %{actor_id: "user_live"})

      try do
        result = Jidoka.chat(session, prompt, timeout: 60_000)

        with {:ok, response} <- JidokaExamples.live_chat_summary(result) do
          {:ok,
           %{
             example: name(),
             mode: :live,
             provider_env: provider_env,
             agent_id: Assistant.id(),
             response: response
           }}
        end
      after
        if pid = Jidoka.Session.whereis(session), do: Jidoka.stop_agent(pid)
      end
    end
  end
end
