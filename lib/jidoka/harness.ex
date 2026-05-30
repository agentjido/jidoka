defmodule Jidoka.Harness do
  @moduledoc """
  Thin execution harness around Jidoka's data-first agent kernel.

  This is intentionally small for V2 MVP. The harness is the named boundary
  where executable turn data, runtime capabilities, checkpoint policy, and resume meet.
  Future session queues, stores, replay, eval cases, and approval flows belong
  here rather than in the root `Jidoka` facade or the pure workflow steps.
  """

  alias Jidoka.Agent
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.TurnRunner
  alias Jidoka.Turn

  @type agent_input :: Agent.Spec.t() | keyword() | map()
  @type plan_input :: Agent.Spec.t() | Turn.Plan.t() | keyword() | map()
  @type request_input :: Turn.Request.t() | String.t() | keyword() | map()
  @type runtime_opts :: keyword()

  @type run_result :: TurnRunner.run_result()

  @doc """
  Runs one agent turn through the harness.
  """
  @spec run_turn(plan_input(), request_input(), runtime_opts()) :: run_result()
  def run_turn(spec_or_plan, request_input, opts \\ []) do
    with {:ok, plan} <- plan(spec_or_plan),
         {:ok, request} <- Turn.Request.from_input(request_input, request_opts(opts)),
         :ok <- Agent.Spec.validate_context(plan.spec, request.context),
         {:ok, capabilities} <- normalize_capabilities(opts) do
      TurnRunner.run(plan, request, capabilities, opts)
    end
  end

  @doc """
  Resumes a hibernated agent snapshot.
  """
  @spec resume(AgentSnapshot.t() | keyword() | map() | String.t(), runtime_opts()) :: run_result()
  def resume(snapshot_input, opts \\ []) do
    with {:ok, snapshot} <- AgentSnapshot.from_input(snapshot_input),
         {:ok, capabilities} <- normalize_capabilities(opts) do
      TurnRunner.resume(snapshot, capabilities, opts)
    end
  end

  @doc false
  @spec plan(plan_input()) :: {:ok, Turn.Plan.t()} | {:error, term()}
  def plan(%Turn.Plan{} = plan), do: {:ok, plan}

  def plan(spec_input) do
    with {:ok, spec} <- Agent.Spec.from_input(spec_input) do
      Turn.Plan.new(spec)
    end
  end

  defp normalize_capabilities(opts) do
    case Keyword.get(opts, :capabilities, Keyword.get(opts, :adapters)) do
      %Capabilities{} = capabilities ->
        {:ok, capabilities}

      capability_attrs when is_list(capability_attrs) or is_map(capability_attrs) ->
        Capabilities.new(capability_attrs)

      nil ->
        Capabilities.new(opts)
    end
  end

  defp request_opts(opts) do
    case Keyword.fetch(opts, :id_generator) do
      {:ok, generator} -> [id_generator: generator]
      :error -> []
    end
  end
end
