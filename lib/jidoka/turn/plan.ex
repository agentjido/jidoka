defmodule Jidoka.Turn.Plan do
  @moduledoc "Executable data compiled from `Jidoka.Agent.Spec`."

  alias Jidoka.Config
  alias Jidoka.ContextWindow.Policy
  alias Jidoka.Operation.Registry
  alias Jidoka.Schema

  @removed_runtime_defaults [:phases, :workflow_profile]

  @schema Zoi.struct(
            __MODULE__,
            %{
              spec: Zoi.lazy({:"Elixir.Jidoka.Agent.Spec", :schema, []}),
              max_model_turns: Zoi.integer() |> Zoi.positive() |> Zoi.default(8),
              timeout_ms: Zoi.integer() |> Zoi.positive() |> Zoi.default(30_000),
              model_candidates: Zoi.array(Zoi.lazy({LLMDB.Model, :schema, []})) |> Zoi.default([]),
              context_policy: Zoi.lazy({Policy, :schema, []}) |> Zoi.default(Policy.new!()),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @type input :: module() | Jidoka.Agent.Spec.t() | t() | keyword() | map()
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for an executable turn plan."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Compiles an agent specification into executable turn data."
  @spec new(Jidoka.Agent.Spec.t()) :: {:ok, t()} | {:error, term()}
  def new(%Jidoka.Agent.Spec{} = spec) do
    with :ok <- reject_removed_runtime_defaults(spec.runtime_defaults),
         {:ok, registry} <- Registry.new(spec.operations),
         spec = %Jidoka.Agent.Spec{spec | operations: Registry.operations(registry)},
         :ok <- Jidoka.Agent.Spec.validate_operation_policies(spec),
         model_candidates = [spec.model],
         {:ok, context_policy} <- Policy.resolve(spec, model_candidates) do
      Schema.parse(@schema, new_attrs(spec, model_candidates, context_policy))
    end
  end

  @doc false
  @spec put_model_candidates(t(), [LLMDB.Model.t()]) :: {:ok, t()} | {:error, term()}
  def put_model_candidates(%__MODULE__{} = plan, [_model | _rest] = model_candidates) do
    with {:ok, context_policy} <- Policy.resolve(plan.spec, model_candidates) do
      Schema.parse(@schema, %__MODULE__{
        plan
        | model_candidates: model_candidates,
          context_policy: context_policy
      })
    end
  end

  def put_model_candidates(%__MODULE__{}, model_candidates),
    do: {:error, {:invalid_plan_model_candidates, model_candidates}}

  @doc "Compiles an agent specification and raises if it is invalid."
  @spec new!(Jidoka.Agent.Spec.t()) :: t()
  def new!(%Jidoka.Agent.Spec{} = spec) do
    case new(spec) do
      {:ok, plan} -> plan
      {:error, reason} -> raise ArgumentError, "invalid turn plan: #{inspect(reason)}"
    end
  end

  @doc false
  @spec normalize_legacy(map()) :: map()
  def normalize_legacy(plan) when is_map(plan) do
    Enum.reduce(@removed_runtime_defaults, plan, fn field, plan ->
      plan
      |> Map.delete(field)
      |> Map.delete(Atom.to_string(field))
    end)
  end

  defp new_attrs(%Jidoka.Agent.Spec{} = spec, model_candidates, %Policy{} = context_policy) do
    defaults = spec.runtime_defaults

    %{
      spec: spec,
      max_model_turns:
        spec.controls.max_turns ||
          default_value(defaults, :max_model_turns, Config.default_max_model_turns()),
      timeout_ms:
        spec.controls.timeout_ms ||
          default_value(
            defaults,
            :timeout_ms,
            default_value(defaults, :timeout, Config.default_turn_timeout_ms())
          ),
      model_candidates: model_candidates,
      context_policy: context_policy,
      metadata: default_value(defaults, :metadata, %{})
    }
  end

  defp default_value(defaults, key, fallback) do
    Map.get(defaults, key, Map.get(defaults, Atom.to_string(key), fallback))
  end

  defp reject_removed_runtime_defaults(defaults) when is_map(defaults) do
    removed =
      Enum.filter(@removed_runtime_defaults, fn key ->
        Map.has_key?(defaults, key) or Map.has_key?(defaults, Atom.to_string(key))
      end)

    if removed == [], do: :ok, else: {:error, {:removed_turn_plan_defaults, removed}}
  end
end
