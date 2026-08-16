defmodule Jidoka.Turn.Prepared do
  @moduledoc """
  Pure, resolved input for one turn.

  The runtime shell resolves instructions, operations, limits, and memory
  before it builds this value. The builder does not call an adapter or store.
  """

  alias Jidoka.Memory
  alias Jidoka.Runtime.Limits
  alias Jidoka.Runtime.Spine.Steps
  alias Jidoka.Turn

  @enforce_keys [:plan, :request, :memory, :limits, :base_state, :state]
  defstruct [:plan, :request, :memory, :limits, :base_state, :state]

  @type t :: %__MODULE__{
          plan: Turn.Plan.t(),
          request: Turn.Request.t(),
          memory: Memory.RecallResult.t() | nil,
          limits: Limits.Applied.t() | nil,
          base_state: Turn.State.t(),
          state: Turn.State.t()
        }

  @doc "Builds deterministic turn data from resolved inputs."
  @spec new(Turn.Plan.t(), Turn.Request.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(%Turn.Plan{} = plan, %Turn.Request{} = request, opts \\ []) when is_list(opts) do
    memory = Keyword.get(opts, :memory)
    limits = Keyword.get(opts, :limits)

    with :ok <- validate_memory(memory),
         :ok <- validate_limits(limits),
         {:ok, base_state} <-
           Turn.State.new(
             spec: plan.spec,
             plan: plan,
             request: request,
             agent_state: request.agent_state,
             memory: memory,
             limits: limit_attrs(limits)
           ),
         {:ok, state} <- prepare_state(base_state) do
      {:ok,
       %__MODULE__{
         plan: plan,
         request: request,
         memory: memory,
         limits: limits,
         base_state: base_state,
         state: state
       }}
    end
  end

  @doc "Applies the pure prompt-preparation rules to one turn state."
  @spec prepare_state(Turn.State.t()) :: {:ok, Turn.State.t()} | {:error, term()}
  def prepare_state(%Turn.State{} = state) do
    case Steps.assemble_prompt(state) do
      %Turn.State{context_projection_error: nil} = state -> {:ok, state}
      %Turn.State{context_projection_error: reason} -> {:error, reason}
    end
  end

  @doc false
  @spec prepare_state!(Turn.State.t()) :: Turn.State.t()
  def prepare_state!(%Turn.State{} = state) do
    case prepare_state(state) do
      {:ok, state} -> state
      {:error, reason} -> %Turn.State{state | context_projection_error: reason}
    end
  end

  defp validate_memory(nil), do: :ok
  defp validate_memory(%Memory.RecallResult{}), do: :ok
  defp validate_memory(memory), do: {:error, {:invalid_resolved_memory, memory}}

  defp validate_limits(nil), do: :ok
  defp validate_limits(%Limits.Applied{}), do: :ok
  defp validate_limits(limits), do: {:error, {:invalid_resolved_limits, limits}}

  defp limit_attrs(%Limits.Applied{} = limits), do: Map.from_struct(limits)
  defp limit_attrs(nil), do: nil
end
