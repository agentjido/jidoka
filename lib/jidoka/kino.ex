defmodule Jidoka.Kino do
  @moduledoc """
  Optional Livebook helpers for inspecting and demonstrating Jidoka agents.

  Kino is not a runtime dependency of Jidoka. These helpers compile and run
  without Kino installed; rendering becomes a no-op outside Livebook. The
  helpers are intentionally thin wrappers around Jidoka data contracts such as
  `Jidoka.inspect/1`, `Jidoka.preflight/3`, `Jidoka.Harness.Replay`, and trace
  timelines.
  """

  alias Jidoka.Kino.{AgentView, Chat, ContextView, Render, RuntimeSetup, TraceView}

  @doc """
  Configures optional notebook conveniences.

  This is opt-in and intended for Livebook/examples. It can mirror Livebook
  secrets such as `LB_OPENAI_API_KEY` into the provider environment expected by
  ReqLLM.
  """
  @spec setup(keyword()) :: :ok
  def setup(opts \\ []), do: RuntimeSetup.setup(opts)

  @doc """
  Configures a notebook and renders a compact setup status table.
  """
  @spec setup_notebook(keyword()) :: map()
  def setup_notebook(opts \\ []), do: RuntimeSetup.setup_notebook(opts)

  @doc """
  Starts a process-hosted Jidoka agent unless an agent with `id` is already running.

  This keeps Livebook cells repeatable when a notebook is re-evaluated.
  """
  @spec start_or_reuse(String.t(), (-> DynamicSupervisor.on_start_child()), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_or_reuse(id, start_fun, opts \\ []), do: RuntimeSetup.start_or_reuse(id, start_fun, opts)

  @doc """
  Mirrors a Livebook provider secret into the normal provider environment.
  """
  @spec load_provider_env([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def load_provider_env(names \\ RuntimeSetup.provider_env_names()), do: RuntimeSetup.load_provider_env(names)

  @doc """
  Runs `fun`, renders a Jidoka timeline when the result contains one, and returns the original result.
  """
  @spec trace(String.t(), (-> result), keyword()) :: result when result: term()
  def trace(label, fun, opts \\ []), do: TraceView.trace(label, fun, opts)

  @doc """
  Runs a notebook chat cell and renders a concise result summary.

  By default this does not require provider credentials; deterministic notebooks
  can pass injected LLM functions. Pass `require_provider?: true` when the cell
  should fail fast if provider credentials are missing.
  """
  @spec chat(String.t(), (-> term()), keyword()) :: term()
  def chat(label, fun, opts \\ []), do: Chat.chat(label, fun, opts)

  @doc """
  Formats common Jidoka turn/session results for notebook display.
  """
  @spec format_chat_result(term()) :: term()
  def format_chat_result(result), do: Chat.format_chat_result(result)

  @doc """
  Renders a runtime context map with public and internal keys separated.
  """
  @spec context(String.t(), map(), keyword()) :: :ok
  def context(label, context, opts \\ []), do: ContextView.context(label, context, opts)

  @doc """
  Renders `Jidoka.inspect/1` for an agent definition, plan, session, or result.
  """
  @spec debug_agent(term(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def debug_agent(target, opts \\ []), do: AgentView.debug_agent(target, opts)

  @doc """
  Renders a request-level debug summary from a turn result, session, snapshot, or replay.
  """
  @spec debug_request(term(), keyword()) :: {:ok, Jidoka.Debug.RequestSummary.t()} | {:error, String.t()}
  def debug_request(target, opts \\ []), do: AgentView.debug_request(target, opts)

  @doc """
  Runs `Jidoka.preflight/3` and renders prompt/timeline tables.
  """
  @spec preflight(Jidoka.plan_input() | module(), Jidoka.request_input(), keyword()) ::
          {:ok, Jidoka.Inspection.Preflight.t()} | {:error, String.t()}
  def preflight(agent_or_plan, request_input, opts \\ []), do: AgentView.preflight(agent_or_plan, request_input, opts)

  @doc """
  Renders a Mermaid diagram for an agent definition or inspection map.
  """
  @spec agent_diagram(term(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def agent_diagram(target, opts \\ []), do: AgentView.agent_diagram(target, opts)

  @doc """
  Renders a compact Jidoka event timeline from a result, snapshot, session, replay, or raw events.
  """
  @spec timeline(term(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def timeline(target, opts \\ []), do: TraceView.timeline(target, opts)

  @doc """
  Renders a Mermaid call graph from a Jidoka timeline.
  """
  @spec call_graph(term(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def call_graph(target, opts \\ []), do: TraceView.call_graph(target, opts)

  @doc """
  Renders the raw compact timeline table.
  """
  @spec trace_table(term(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def trace_table(target, opts \\ []), do: TraceView.trace_table(target, opts)

  @doc """
  Renders a small Markdown table in Livebook.
  """
  @spec table(String.t(), [map()], keyword()) :: :ok
  def table(label, rows, opts \\ []), do: Render.table(label, rows, opts)
end
