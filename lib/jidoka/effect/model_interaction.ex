defmodule Jidoka.Effect.ModelInteraction do
  @moduledoc """
  Durable semantic record for one model response.

  Tool requests from one response form one ordered tool-call group. A legacy
  singular operation therefore becomes a group with one call.
  """

  alias Jidoka.Effect
  alias Jidoka.Id
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              interaction_id: Schema.non_empty_string(),
              tool_call_groups:
                Zoi.array(Zoi.lazy({Effect.ToolCallGroup, :schema, []}))
                |> Zoi.default([]),
              provider_metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a model interaction."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds and validates a model interaction."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, %__MODULE__{} = interaction} <- Schema.parse(@schema, attrs),
         :ok <- validate_groups(interaction) do
      {:ok, interaction}
    end
  end

  @doc "Builds a model interaction and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, interaction} -> interaction
      {:error, reason} -> raise ArgumentError, "invalid model interaction: #{inspect(reason)}"
    end
  end

  @doc "Normalizes an existing model interaction, keyword list, or map."
  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = interaction), do: new(interaction)
  def from_input(input), do: new(input)

  @doc "Creates a durable interaction record from a model decision."
  @spec from_decision(struct(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_decision(decision, opts \\ [])

  def from_decision(
        %{__struct__: Effect.LLMDecision, interaction: %__MODULE__{} = interaction},
        _opts
      ),
      do: new(interaction)

  def from_decision(%{__struct__: Effect.LLMDecision} = decision, opts) when is_list(opts) do
    with {:ok, interaction_id} <- id(:interaction, opts, :interaction_id),
         {:ok, groups} <- tool_call_groups(decision, interaction_id, opts) do
      new(
        interaction_id: interaction_id,
        tool_call_groups: groups,
        provider_metadata: Keyword.get(opts, :provider_metadata, decision.metadata)
      )
    end
  end

  @doc "Projects a model interaction to durable data."
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = interaction) do
    %{
      interaction_id: interaction.interaction_id,
      tool_call_groups: Enum.map(interaction.tool_call_groups, &Effect.ToolCallGroup.to_payload/1)
    }
    |> maybe_put_provider_metadata(interaction.provider_metadata)
  end

  defp tool_call_groups(
         %{__struct__: Effect.LLMDecision, type: :final},
         _interaction_id,
         _opts
       ),
       do: {:ok, []}

  defp tool_call_groups(%{__struct__: Effect.LLMDecision} = decision, interaction_id, opts) do
    operations = normalized_operations(decision)

    with {:ok, group_id} <- id(:group, opts, :group_id),
         {:ok, group} <-
           Effect.ToolCallGroup.from_operations(operations,
             interaction_id: interaction_id,
             group_id: group_id,
             provider_metadata: Keyword.get(opts, :group_provider_metadata, %{})
           ) do
      {:ok, [group]}
    end
  end

  defp normalized_operations(%{
         __struct__: Effect.LLMDecision,
         type: :operation,
         operations: [operation]
       }),
       do: [operation]

  defp normalized_operations(%{
         __struct__: Effect.LLMDecision,
         type: :operation,
         name: name,
         arguments: arguments
       }) do
    [Effect.OperationRequest.new!(name: name, arguments: arguments)]
  end

  defp normalized_operations(%{
         __struct__: Effect.LLMDecision,
         type: :operations,
         operations: operations
       }),
       do: operations

  defp validate_groups(%__MODULE__{} = interaction) do
    interaction.tool_call_groups
    |> Enum.reduce_while(:ok, fn group, :ok ->
      with {:ok, group} <- Effect.ToolCallGroup.from_input(group),
           true <- group.interaction_id == interaction.interaction_id do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :tool_call_group_interaction_mismatch}}
        {:error, reason} -> {:halt, {:error, {:invalid_tool_call_group, reason}}}
      end
    end)
  end

  defp id(prefix, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_interaction_id, key, value}}
      :error -> Id.generate(Atom.to_string(prefix), Keyword.get(opts, :id_generator))
    end
  end

  defp maybe_put_provider_metadata(payload, metadata) when metadata == %{}, do: payload
  defp maybe_put_provider_metadata(payload, metadata), do: Map.put(payload, :provider_metadata, metadata)
end
