defmodule Jidoka.Agent.RuntimeOptions do
  @moduledoc false

  alias Jidoka.Adapter.ReqLLM
  alias Jidoka.Agent.Spec
  alias Jidoka.Agent.Spec.Generation
  alias Jidoka.Agent.ToolSources
  alias Jidoka.ModelPolicy

  @spec resolve(module(), Spec.t(), keyword()) :: keyword()
  def resolve(agent_module, %Spec{} = spec, opts)
      when is_atom(agent_module) and is_list(opts) do
    opts
    |> ensure_operation_source(agent_module)
    |> Keyword.put(:operation_context, operation_context(agent_module, spec, opts))
    |> Keyword.put_new_lazy(:llm, fn -> ReqLLM.llm(default_llm_opts(spec, opts)) end)
  end

  defp ensure_operation_source(opts, agent_module) do
    if Keyword.has_key?(opts, :operations) and Keyword.has_key?(opts, :dsl_operation_source_digest) do
      opts
    else
      compiled = ToolSources.compile!(agent_module)

      opts
      |> Keyword.put_new(:operations, compiled.capability)
      |> Keyword.put_new(:dsl_operation_source_digest, compiled.digest)
    end
  end

  defp operation_context(agent_module, %Spec{} = spec, opts) do
    base = %{
      agent_module: agent_module,
      jido_agent: agent_module.new(),
      jidoka_spec: spec
    }

    Map.merge(base, normalize_operation_context(Keyword.get(opts, :operation_context, %{})))
  end

  defp normalize_operation_context(%Jidoka.Context{} = context),
    do: Jidoka.Context.runtime(context)

  defp normalize_operation_context(context) when is_list(context) do
    if Keyword.keyword?(context), do: Map.new(context), else: %{}
  end

  defp normalize_operation_context(context) when is_map(context), do: context
  defp normalize_operation_context(_context), do: %{}

  defp default_llm_opts(%Spec{} = spec, opts) do
    spec.generation
    |> Generation.to_req_llm_opts()
    |> Keyword.merge(Keyword.get(opts, :llm_opts, []))
    |> Keyword.merge(Keyword.take(opts, [:stream, :stream_to, :on_event]))
    |> ModelPolicy.configure_llm_opts(spec.model, opts)
  end
end
