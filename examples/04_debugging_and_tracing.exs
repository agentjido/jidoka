Mix.Task.run("app.start")

defmodule JidokaExamples.Debugging.DebugAgent do
  use Jidoka.Agent

  agent :example_debug_agent do
    model :fast
    instructions "This agent is used to show request inspection and tracing."
  end
end

alias JidokaExamples.Debugging.DebugAgent

session =
  DebugAgent
  |> Jidoka.session("debug-session", context: %{actor_id: "user_123"})

stop_before_provider = fn input ->
  Jidoka.Approval.request("Stop before the provider so this example stays deterministic.",
    data: %{message: input.message}
  )
end

try do
  {:interrupt, interrupt} =
    Jidoka.chat(session, "Show me the current runtime state.", controls: [input: stop_before_provider])

  {:ok, request} = Jidoka.inspect_request(session)
  {:ok, trace} = Jidoka.inspect_trace(session)

  IO.inspect(
    %{
      interrupt: Map.take(interrupt, [:kind, :message, :data]),
      request_id: request.request_id,
      input_message: request.input_message,
      trace_categories: trace.events |> Enum.map(& &1.category) |> Enum.uniq()
    },
    label: "debugging_and_tracing"
  )
after
  if pid = Jidoka.Session.whereis(session), do: Jidoka.stop_agent(pid)
end
