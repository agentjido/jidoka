defmodule Jidoka.Lifecycle.State do
  @moduledoc false

  @enforce_keys [:agent]
  defstruct [
    :agent,
    :action,
    :result,
    directives: [],
    status: :cont
  ]

  @type status :: :cont | :halt

  @type t :: %__MODULE__{
          agent: Jido.Agent.t(),
          action: term(),
          directives: [term()],
          status: status(),
          result: term()
        }

  @schema Zoi.object(%{
            agent: Zoi.any(),
            action: Zoi.any() |> Zoi.optional(),
            directives: Zoi.list(Zoi.any()) |> Zoi.default([]),
            status: Zoi.enum([:cont, :halt]) |> Zoi.default(:cont),
            result: Zoi.any() |> Zoi.optional()
          })

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    with {:ok, parsed} <- Zoi.parse(@schema, attrs) do
      {:ok, struct(__MODULE__, parsed)}
    end
  end

  def new(other), do: {:error, {:invalid_lifecycle_state, other}}

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, state} -> state
      {:error, reason} -> raise ArgumentError, "invalid Jidoka lifecycle state: #{inspect(reason)}"
    end
  end

  @spec put_agent_action(t(), Jido.Agent.t(), term()) :: t()
  def put_agent_action(%__MODULE__{} = state, agent, action) do
    %{state | agent: agent, action: action}
  end

  @spec put_agent_directives(t(), Jido.Agent.t(), [term()]) :: t()
  def put_agent_directives(%__MODULE__{} = state, agent, directives) when is_list(directives) do
    %{state | agent: agent, directives: directives}
  end

  @spec halt(t(), term()) :: t()
  def halt(%__MODULE__{} = state, result), do: %{state | status: :halt, result: result}
end
