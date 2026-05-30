defmodule Jidoka.Turn.Plan do
  @moduledoc "Executable data compiled from `Jidoka.Agent.Spec`."

  alias Jidoka.Agent
  alias Jidoka.Config
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
              spec: Zoi.lazy({Agent.Spec, :schema, []}),
              workflow_profile: Schema.atom_enum(@workflow_profiles) |> Zoi.default(:tool_loop),
              max_model_turns: Zoi.integer() |> Zoi.positive() |> Zoi.default(8),
              timeout_ms: Zoi.integer() |> Zoi.positive() |> Zoi.default(30_000),
              phases: Zoi.array(Schema.atom_enum(@phases)) |> Zoi.default(@phases),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(Agent.Spec.t()) :: {:ok, t()} | {:error, term()}
  def new(%Agent.Spec{} = spec) do
    with :ok <- Agent.Spec.validate_operation_policies(spec) do
      Schema.parse(@schema, new_attrs(spec))
    end
  end

  @spec new!(Agent.Spec.t()) :: t()
  def new!(%Agent.Spec{} = spec) do
    case new(spec) do
      {:ok, plan} -> plan
      {:error, reason} -> raise ArgumentError, "invalid turn plan: #{inspect(reason)}"
    end
  end

  defp new_attrs(%Agent.Spec{} = spec) do
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
      phases: default_value(defaults, :phases, @phases),
      metadata: default_value(defaults, :metadata, %{})
    }
  end

  defp default_value(defaults, key, fallback) do
    Map.get(defaults, key, Map.get(defaults, Atom.to_string(key), fallback))
  end
end
