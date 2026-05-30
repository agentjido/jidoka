defmodule Jidoka.Trace.Sink do
  @moduledoc """
  Behaviour and delegator for trace sinks.

  A trace sink receives already-projected and policy-filtered trace entries. It
  should not need access to runtime capabilities, credentials, or mutable agent
  state.
  """

  alias Jidoka.Trace.Policy

  @type sink :: module() | {module(), keyword() | map()}

  @callback record([map()], Policy.t(), keyword()) :: :ok | {:error, term()}

  @spec record(sink(), [map()], Policy.t(), keyword()) :: :ok | {:error, term()}
  def record(sink, entries, policy, opts \\ [])

  def record({module, sink_opts}, entries, %Policy{} = policy, opts)
      when is_atom(module) and is_list(entries) do
    record_module(module, entries, policy, merge_opts(sink_opts, opts))
  end

  def record(module, entries, %Policy{} = policy, opts)
      when is_atom(module) and is_list(entries) do
    record_module(module, entries, policy, opts)
  end

  def record(sink, _entries, _policy, _opts), do: {:error, {:invalid_trace_sink, sink}}

  defp record_module(module, entries, policy, opts) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :record, 3) do
      module.record(entries, policy, opts)
    else
      _other -> {:error, {:invalid_trace_sink, module}}
    end
  end

  defp merge_opts(sink_opts, opts) when is_map(sink_opts),
    do: Keyword.merge(Map.to_list(sink_opts), opts)

  defp merge_opts(sink_opts, opts) when is_list(sink_opts), do: Keyword.merge(sink_opts, opts)
  defp merge_opts(_sink_opts, opts), do: opts
end
