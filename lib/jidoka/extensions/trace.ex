defmodule Jidoka.Extensions.Trace do
  @moduledoc """
  Built-in trace extension.

  Trace is the first extension because it observes the harness without changing
  agent behavior. It proves the extension shape while keeping the core loop
  thin and inspectable.
  """

  use Jidoka.Extension

  @impl true
  def name, do: :trace

  @impl true
  def events, do: Jidoka.Trace.events()

  @doc "Projects core events into a trace timeline."
  @spec timeline(list()) :: [map()]
  def timeline(events), do: Jidoka.Trace.timeline(events)
end
