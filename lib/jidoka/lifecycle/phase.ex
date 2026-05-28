defmodule Jidoka.Lifecycle.Phase do
  @moduledoc false

  alias Jidoka.Lifecycle.State

  @enforce_keys [:name, :stage, :runner]
  defstruct [:name, :stage, :runner, :feature]

  @type stage :: :before | :after

  @type t :: %__MODULE__{
          name: atom(),
          stage: stage(),
          feature: atom() | nil,
          runner: (State.t() -> {:ok, State.t()} | {:halt, term()} | State.t())
        }

  @schema Zoi.object(%{
            name: Zoi.atom(),
            stage: Zoi.enum([:before, :after]),
            feature: Zoi.atom() |> Zoi.optional(),
            runner: Zoi.any()
          })

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    with {:ok, parsed} <- Zoi.parse(@schema, attrs),
         :ok <- validate_runner(parsed.runner) do
      {:ok, struct(__MODULE__, parsed)}
    end
  end

  def new(other), do: {:error, {:invalid_lifecycle_phase, other}}

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, phase} -> phase
      {:error, reason} -> raise ArgumentError, "invalid Jidoka lifecycle phase: #{inspect(reason)}"
    end
  end

  @spec run(t(), State.t()) :: State.t()
  def run(%__MODULE__{}, %State{status: :halt} = state), do: state

  def run(%__MODULE__{runner: runner}, %State{} = state) do
    try do
      case runner.(state) do
        {:ok, %State{} = state} -> state
        {:halt, result} -> State.halt(state, result)
        %State{} = state -> state
        other -> State.halt(state, other)
      end
    catch
      kind, reason ->
        State.halt(state, {{__MODULE__, :failure}, kind, reason, __STACKTRACE__})
    end
  end

  @doc false
  @spec raise_if_failed(State.t()) :: State.t()
  def raise_if_failed(%State{
        status: :halt,
        result: {{__MODULE__, :failure}, kind, reason, stacktrace}
      }) do
    :erlang.raise(kind, reason, stacktrace)
  end

  def raise_if_failed(%State{} = state), do: state

  defp validate_runner(runner) when is_function(runner, 1), do: :ok
  defp validate_runner(runner), do: {:error, {:invalid_lifecycle_phase_runner, runner}}
end
