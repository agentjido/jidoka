defmodule Jidoka.Turn.Execution do
  @moduledoc """
  Application use case for one direct or resumed agent turn.

  This module prepares pure turn data, resolves injected capabilities, and
  calls the runtime shell. It does not own sessions or persistence.
  """

  alias Jidoka.Agent
  alias Jidoka.Agent.RuntimeOptions
  alias Jidoka.Agent.Spec.Generation
  alias Jidoka.Adapter.Runic.OperationBatch
  alias Jidoka.Adapter.Runic.TurnCompiler
  alias Jidoka.Instructions
  alias Jidoka.Memory
  alias Jidoka.ModelPolicy
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Adapter.ReqLLM
  alias Jidoka.Runtime.TurnRunner
  alias Jidoka.Schema
  alias Jidoka.Snapshot
  alias Jidoka.Turn

  @type plan_input :: module() | Agent.Spec.t() | Turn.Plan.t() | keyword() | map()
  @type request_input ::
          Turn.Request.t() | String.t() | [Jidoka.ContentPart.input()] | keyword() | map()
  @type opts :: keyword()
  @type result :: TurnRunner.run_result()
  @type prepared :: %{
          plan: Turn.Plan.t(),
          request: Turn.Request.t(),
          capabilities: Capabilities.t(),
          opts: keyword()
        }

  @doc "Runs one agent turn through the runtime shell."
  @spec run(plan_input(), request_input(), opts()) :: result()
  def run(spec_or_plan, request_input, opts \\ []) do
    with {:ok, prepared} <- prepare(spec_or_plan, request_input, opts) do
      prepared.plan
      |> TurnRunner.run(prepared.request, prepared.capabilities, prepared.opts)
      |> maybe_capture_memory(prepared.plan.spec, prepared.request, prepared.opts)
    end
  end

  @doc false
  @spec prepare(plan_input(), request_input(), opts()) :: {:ok, prepared()} | {:error, term()}
  def prepare(spec_or_plan, request_input, opts \\ []) do
    with {:ok, plan} <- plan(spec_or_plan),
         opts = runtime_opts(plan, opts),
         {:ok, request} <- Turn.Request.from_input(request_input, request_opts(opts)),
         :ok <- Agent.Spec.validate_context(plan.spec, request.context),
         {:ok, plan} <- Instructions.resolve(plan, request, opts),
         {:ok, memory} <- Memory.Runtime.recall(plan.spec, request, opts),
         {:ok, capabilities} <- normalize_capabilities(opts) do
      {:ok,
       %{
         plan: plan,
         request: request,
         capabilities: capabilities,
         opts: Keyword.put(opts, :memory, memory)
       }}
    end
  end

  @doc "Resumes one hibernated snapshot through the runtime shell."
  @spec resume(Snapshot.t() | String.t(), opts()) :: result()
  def resume(snapshot_input, opts \\ []) do
    with {:ok, prepared} <- prepare_resume(snapshot_input, opts) do
      TurnRunner.resume(prepared.snapshot, prepared.capabilities, prepared.opts)
    end
  end

  @doc false
  @spec prepare_resume(Snapshot.t() | String.t(), opts()) ::
          {:ok, %{snapshot: Snapshot.t(), capabilities: Capabilities.t(), opts: keyword()}}
          | {:error, term()}
  def prepare_resume(snapshot_input, opts \\ []) do
    with {:ok, snapshot} <- Snapshot.from_input(snapshot_input),
         opts = runtime_opts(snapshot, opts),
         {:ok, capabilities} <- normalize_capabilities(opts) do
      {:ok, %{snapshot: snapshot, capabilities: capabilities, opts: opts}}
    end
  end

  @doc "Compiles agent definition data into a turn plan."
  @spec plan(plan_input()) :: {:ok, Turn.Plan.t()} | {:error, term()}
  def plan(%Turn.Plan{} = plan), do: {:ok, plan}

  def plan(spec_input) do
    with {:ok, spec} <- Agent.Spec.from_input(spec_input) do
      Turn.Plan.new(spec)
    end
  end

  defp maybe_capture_memory({:ok, %Turn.Result{} = result} = ok, spec, request, opts) do
    _capture = Memory.Runtime.capture_turn(spec, request, result, opts)
    ok
  end

  defp maybe_capture_memory(result, _spec, _request, _opts), do: result

  defp runtime_opts(%Turn.Plan{spec: %Agent.Spec{} = spec}, opts), do: runtime_opts(spec, opts)

  defp runtime_opts(%Snapshot{turn_state: %{spec: %Agent.Spec{} = spec}}, opts),
    do: runtime_opts(spec, opts)

  defp runtime_opts(%Agent.Spec{} = spec, opts) do
    opts =
      case dsl_agent_module(spec) do
        nil -> Keyword.put_new(opts, :llm, ReqLLM.llm(default_llm_opts(spec, opts)))
        agent_module -> RuntimeOptions.resolve(agent_module, spec, opts)
      end

    opts
    |> Keyword.put_new(:model_turn_executor, &TurnCompiler.run_model_turn/2)
    |> Keyword.put_new(:operation_batch_executor, &OperationBatch.execute/5)
  end

  defp dsl_agent_module(%Agent.Spec{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("dsl_module", Map.get(metadata, :dsl_module))
    |> existing_dsl_agent_module()
  end

  defp existing_dsl_agent_module(module_name) when is_binary(module_name) do
    module = module_name |> String.trim() |> module_atom()

    if Code.ensure_loaded?(module) and function_exported?(module, :__jidoka_agent__, 0), do: module
  rescue
    ArgumentError -> nil
  end

  defp existing_dsl_agent_module(_module_name), do: nil

  defp module_atom("Elixir." <> _rest = module_name), do: String.to_existing_atom(module_name)
  defp module_atom(module_name), do: String.to_existing_atom("Elixir." <> module_name)

  defp default_llm_opts(%Agent.Spec{} = spec, opts) do
    spec.generation
    |> Generation.to_req_llm_opts()
    |> Keyword.merge(Keyword.get(opts, :llm_opts, []))
    |> Keyword.merge(Keyword.take(opts, [:stream, :stream_to, :on_event]))
    |> ModelPolicy.configure_llm_opts(spec.model, opts)
  end

  defp normalize_capabilities(opts) do
    capabilities =
      case Keyword.get(opts, :capabilities) do
        %Capabilities{} = capabilities ->
          {:ok, capabilities}

        capability_attrs when is_list(capability_attrs) or is_map(capability_attrs) ->
          capability_attrs
          |> capability_attrs_with_defaults(opts)
          |> Capabilities.new()

        nil ->
          Capabilities.new(opts)
      end

    with {:ok, capabilities} <- capabilities do
      ModelPolicy.wrap(capabilities, Keyword.get(opts, :model_policy))
    end
  end

  defp capability_attrs_with_defaults(capability_attrs, opts) do
    [:llm, :operations, :policy]
    |> Enum.reduce(Schema.normalize_attrs(capability_attrs), fn capability, attrs ->
      case Keyword.fetch(opts, capability) do
        {:ok, value} -> Schema.put_default(attrs, capability, value)
        :error -> attrs
      end
    end)
  end

  defp request_opts(opts) do
    opts
    |> Keyword.take([:id_generator, :request_id, :context, :metadata])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
