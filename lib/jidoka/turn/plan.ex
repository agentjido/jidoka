defmodule Jidoka.Turn.Plan do
  @moduledoc "Executable data compiled from `Jidoka.Agent.Spec`."

  alias Jidoka.Config
  alias Jidoka.ContextWindow.Policy
  alias Jidoka.Operation.Registry
  alias Jidoka.Schema

  @phases [
    :assemble_prompt,
    :plan_model_effect,
    :apply_model_result,
    :plan_operation_effects,
    :apply_operation_results
  ]
  @workflow_profiles [:chat, :tool_loop, :structured_result, :controlled_tool_loop]

  @schema Zoi.struct(
            __MODULE__,
            %{
              spec: Zoi.lazy({:"Elixir.Jidoka.Agent.Spec", :schema, []}),
              workflow_profile: Schema.atom_enum(@workflow_profiles) |> Zoi.default(:tool_loop),
              max_model_turns: Zoi.integer() |> Zoi.positive() |> Zoi.default(8),
              timeout_ms: Zoi.integer() |> Zoi.positive() |> Zoi.default(30_000),
              context_policy: Zoi.lazy({Policy, :schema, []}) |> Zoi.default(Policy.new!()),
              phases: Zoi.array(Schema.atom_enum(@phases)) |> Zoi.default(@phases),
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
    with {:ok, registry} <- Registry.new(spec.operations),
         spec = %Jidoka.Agent.Spec{spec | operations: Registry.operations(registry)},
         :ok <- Jidoka.Agent.Spec.validate_operation_policies(spec),
         {:ok, context_policy} <- Policy.resolve(spec) do
      Schema.parse(@schema, new_attrs(spec, context_policy))
    end
  end

  @doc "Compiles an agent specification and raises if it is invalid."
  @spec new!(Jidoka.Agent.Spec.t()) :: t()
  def new!(%Jidoka.Agent.Spec{} = spec) do
    case new(spec) do
      {:ok, plan} -> plan
      {:error, reason} -> raise ArgumentError, "invalid turn plan: #{inspect(reason)}"
    end
  end

  defp new_attrs(%Jidoka.Agent.Spec{} = spec, %Policy{} = context_policy) do
    defaults = spec.runtime_defaults

    %{
      spec: spec,
      workflow_profile: default_value(defaults, :workflow_profile, :tool_loop),
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
      context_policy: context_policy,
      phases: default_value(defaults, :phases, @phases),
      metadata: default_value(defaults, :metadata, %{})
    }
  end

  defp default_value(defaults, key, fallback) do
    Map.get(defaults, key, Map.get(defaults, Atom.to_string(key), fallback))
  end
end
