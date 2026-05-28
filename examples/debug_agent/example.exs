defmodule JidokaExamples.DebugAgentExample do
  @behaviour JidokaExamples.Example

  alias JidokaExamples.Debugging.DebugAgent

  @impl true
  def name, do: :debug_agent

  @impl true
  def title, do: "Debug Agent"

  @impl true
  def features, do: [:inspection, :trace, :interrupts]

  @impl true
  def summary, do: "Interrupts before the provider, then inspects the request and structured trace."

  @impl true
  def run(opts \\ []) do
    case JidokaExamples.mode(opts) do
      :live -> run_live(opts)
      :verify -> run_verify(opts)
    end
  end

  defp run_verify(opts) do
    prompt = JidokaExamples.prompt(opts, "Show me the current runtime state.")
    session = Jidoka.session(DebugAgent, "debug-session", context: %{actor_id: "user_123"})

    stop_before_provider = fn input ->
      Jidoka.Approval.request("Stop before the provider so this example stays deterministic.",
        data: %{request_id: input.request_id, message: input.message}
      )
    end

    try do
      {:interrupt, interrupt} = Jidoka.chat(session, prompt, controls: [input: stop_before_provider])
      {:ok, request} = Jidoka.inspect_request(session)
      {:ok, trace} = Jidoka.inspect_trace(session)
      {:ok, preflight} = DebugAgent.prompt_preflight(prompt, context: Jidoka.Session.chat_opts(session)[:context])

      {:ok,
       %{
         example: name(),
         mode: :verify,
         interrupt: Map.take(interrupt, [:kind, :message, :data]),
         request_id: request.request_id,
         input_message: request.input_message,
         prompt_sections: Enum.map(preflight.sections, & &1.name),
         trace_categories: trace.events |> Enum.map(& &1.category) |> Enum.uniq()
       }}
    after
      if pid = Jidoka.Session.whereis(session), do: Jidoka.stop_agent(pid)
    end
  end

  defp run_live(opts) do
    with {:ok, provider_env} <- JidokaExamples.require_live_provider(opts) do
      prompt = JidokaExamples.prompt(opts, "Reply with the word ready and one short reason.")
      session = Jidoka.session(DebugAgent, "debug-live", context: %{actor_id: "user_live"})

      try do
        result = Jidoka.chat(session, prompt, timeout: 60_000)
        {:ok, trace} = Jidoka.inspect_trace(session)

        with {:ok, response} <- JidokaExamples.live_chat_summary(result) do
          {:ok,
           %{
             example: name(),
             mode: :live,
             provider_env: provider_env,
             response: response,
             trace_event_count: length(trace.events)
           }}
        end
      after
        if pid = Jidoka.Session.whereis(session), do: Jidoka.stop_agent(pid)
      end
    end
  end
end
