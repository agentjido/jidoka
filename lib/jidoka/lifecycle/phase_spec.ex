defmodule Jidoka.Lifecycle.PhaseSpec do
  @moduledoc false

  alias Jidoka.Lifecycle.{Phase, State}

  @enforce_keys [:name, :stage, :feature, :runner]
  defstruct [:name, :stage, :feature, :runner]

  @type stage :: Phase.stage()
  @type runner :: (State.t() -> {:ok, State.t()} | {:halt, term()} | State.t() | term())

  @type t :: %__MODULE__{
          name: atom(),
          stage: stage(),
          feature: atom(),
          runner: runner()
        }

  @schema Zoi.object(%{
            name: Zoi.atom(),
            stage: Zoi.enum([:before, :after]),
            feature: Zoi.atom(),
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

  def new(other), do: {:error, {:invalid_lifecycle_phase_spec, other}}

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, "invalid Jidoka lifecycle phase spec: #{inspect(reason)}"
    end
  end

  @spec before(atom(), atom(), (term(), term() -> {:ok, term(), term()} | term())) :: t()
  def before(name, feature, fun) when is_atom(name) and is_atom(feature) and is_function(fun, 2) do
    new!(
      name: name,
      stage: :before,
      feature: feature,
      runner: fn %State{} = state ->
        case fun.(state.agent, state.action) do
          {:ok, agent, action} -> {:ok, State.put_agent_action(state, agent, action)}
          other -> {:halt, other}
        end
      end
    )
  end

  @spec after_phase(atom(), atom(), (term(), term(), [term()] -> {:ok, term(), [term()]} | term())) :: t()
  def after_phase(name, feature, fun) when is_atom(name) and is_atom(feature) and is_function(fun, 3) do
    new!(
      name: name,
      stage: :after,
      feature: feature,
      runner: fn %State{} = state ->
        case fun.(state.agent, state.action, state.directives) do
          {:ok, agent, directives} -> {:ok, State.put_agent_directives(state, agent, directives)}
          other -> {:halt, other}
        end
      end
    )
  end

  @spec compile(t()) :: {:ok, Phase.t()} | {:error, term()}
  def compile(%__MODULE__{} = spec) do
    Phase.new(name: spec.name, stage: spec.stage, feature: spec.feature, runner: spec.runner)
  end

  @spec compile!(t()) :: Phase.t()
  def compile!(%__MODULE__{} = spec) do
    case compile(spec) do
      {:ok, phase} -> phase
      {:error, reason} -> raise ArgumentError, "invalid Jidoka lifecycle phase: #{inspect(reason)}"
    end
  end

  @spec compile_all([t()]) :: [Phase.t()]
  def compile_all(specs) when is_list(specs), do: Enum.map(specs, &compile!/1)

  defp validate_runner(runner) when is_function(runner, 1), do: :ok
  defp validate_runner(runner), do: {:error, {:invalid_lifecycle_phase_spec_runner, runner}}
end
