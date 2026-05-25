defmodule Jidoka.Kino do
  @moduledoc """
  Small Livebook helpers for Jidoka examples.

  `Jidoka.Kino` keeps notebook cells focused on the agent code. It configures
  quiet runtime logs, mirrors Livebook secrets into the provider environment,
  captures useful Jido/Jidoka log events, and renders those events with Kino
  when Kino is available.

  Kino is intentionally optional. This module compiles and runs without Kino;
  rendering becomes a no-op outside Livebook.
  """

  alias Jidoka.Kino.{AgentView, Chat, ContextView, LogTrace, Render, RuntimeSetup, TraceView}

  @doc """
  Configures the notebook runtime for concise Jidoka output.

  By default, raw runtime logs are quiet and provider-backed examples can rely
  on a Livebook secret named `ANTHROPIC_API_KEY`.
  """
  @spec setup(keyword()) :: :ok
  def setup(opts \\ []), do: RuntimeSetup.setup(opts)

  @doc """
  Starts a Jidoka agent unless an agent with `id` is already running.

  This keeps Livebook cells repeatable. `start_fun` should be a zero-arity
  function that returns the normal `{:ok, pid}` agent start result.
  """
  @spec start_or_reuse(String.t(), (-> {:ok, pid()} | {:error, term()})) ::
          {:ok, pid()} | {:error, term()}
  def start_or_reuse(id, start_fun), do: RuntimeSetup.start_or_reuse(id, start_fun)

  @doc """
  Copies a Livebook provider secret into the environment name expected by ReqLLM.

  The default lookup accepts either `ANTHROPIC_API_KEY` or Livebook's
  `LB_ANTHROPIC_API_KEY`.
  """
  @spec load_provider_env([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def load_provider_env(names \\ RuntimeSetup.provider_env_names()), do: RuntimeSetup.load_provider_env(names)

  @doc """
  Captures runtime log events around `fun` and renders a compact trace table.
  """
  @spec trace(String.t(), (-> result), keyword()) :: result when result: term()
  def trace(label, fun, opts \\ []), do: LogTrace.trace(label, fun, opts)

  @doc """
  Captures a provider-backed chat call and returns plain extracted text.
  """
  @spec chat(String.t(), (-> term()), keyword()) :: term()
  def chat(label, fun, opts \\ []), do: Chat.chat(label, fun, opts)

  @doc """
  Formats common Jidoka chat results for notebook output.
  """
  @spec format_chat_result(term()) :: term()
  def format_chat_result(result), do: Chat.format_chat_result(result)

  @doc """
  Renders a runtime context map with public and internal keys separated.
  """
  @spec context(String.t(), map(), keyword()) :: :ok
  def context(label, context, opts \\ []), do: ContextView.context(label, context, opts)

  @doc """
  Renders Jidoka's inspection summary for an agent definition or running agent.
  """
  @spec debug_agent(module() | struct() | pid() | String.t() | map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def debug_agent(target, opts \\ []), do: AgentView.debug_agent(target, opts)

  @doc """
  Renders a bounded request summary for the latest turn or a specific request.

  Pass `request_id: "..."` to inspect an older request on a running agent.
  """
  @spec debug_request(Jidoka.Session.t() | pid() | String.t() | Jido.Agent.t() | map(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def debug_request(target, opts \\ []), do: AgentView.debug_request(target, opts)

  @doc """
  Renders a Mermaid diagram of an agent's model, context, lifecycle, and tools.
  """
  @spec agent_diagram(module() | struct() | pid() | String.t() | map(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def agent_diagram(target, opts \\ []), do: AgentView.agent_diagram(target, opts)

  @doc """
  Renders the latest structured Jidoka trace as a compact timeline.
  """
  @spec timeline(Jidoka.Trace.t() | pid() | String.t() | Jido.Agent.t(), keyword()) ::
          {:ok, Jidoka.Trace.t()} | {:error, String.t()}
  def timeline(target, opts \\ []), do: TraceView.timeline(target, opts)

  @doc """
  Renders a Mermaid call graph for the latest structured Jidoka trace.
  """
  @spec call_graph(Jidoka.Trace.t() | pid() | String.t() | Jido.Agent.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def call_graph(target, opts \\ []), do: TraceView.call_graph(target, opts)

  @doc """
  Renders the raw structured events for the latest Jidoka trace.
  """
  @spec trace_table(Jidoka.Trace.t() | pid() | String.t() | Jido.Agent.t(), keyword()) ::
          {:ok, Jidoka.Trace.t()} | {:error, String.t()}
  def trace_table(target, opts \\ []), do: TraceView.trace_table(target, opts)

  @doc """
  Renders the latest Jidoka compaction snapshot, if any.
  """
  @spec compaction(Jidoka.Session.t() | pid() | String.t() | Jido.Agent.t(), keyword()) ::
          {:ok, Jidoka.Compaction.t() | nil} | {:error, String.t()}
  def compaction(target, opts \\ []) do
    case Jidoka.inspect_compaction(target, opts) do
      {:ok, nil} ->
        Render.markdown("### Compaction\n\nNo compaction has run for this agent.")
        {:ok, nil}

      {:ok, %Jidoka.Compaction{} = compaction} ->
        rows = [
          %{property: "status", value: compaction.status},
          %{property: "strategy", value: compaction.strategy},
          %{property: "source messages", value: compaction.source_message_count},
          %{property: "retained messages", value: compaction.retained_message_count},
          %{property: "summary", value: compaction.summary_preview || "-"}
        ]

        Render.table("Compaction", rows, keys: [:property, :value])
        {:ok, compaction}

      {:error, reason} ->
        message = Jidoka.Error.format(reason)
        Render.markdown("### Compaction\n\n#{Render.escape_markdown(message)}")
        {:error, message}
    end
  end

  @doc """
  Renders a small Markdown table in Livebook.

  This avoids custom widget JavaScript, so it remains stable across Livebook and
  Kino versions.
  """
  @spec table(String.t(), [map()], keyword()) :: :ok
  def table(label, rows, opts \\ []), do: Render.table(label, rows, opts)
end
