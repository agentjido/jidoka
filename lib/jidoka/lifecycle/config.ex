defmodule Jidoka.Lifecycle.Config do
  @moduledoc false

  @enforce_keys [:hooks, :context, :guardrails, :mcp_tools]
  defstruct [
    :hooks,
    :guardrails,
    :timeouts,
    :compaction,
    :memory,
    :output,
    :skills,
    context: %{},
    mcp_tools: []
  ]

  @type t :: %__MODULE__{
          hooks: Jidoka.Hooks.stage_map(),
          context: map(),
          guardrails: Jidoka.Guardrails.stage_map(),
          timeouts: Jidoka.Lifecycle.Timeouts.t(),
          compaction: Jidoka.Compaction.config() | nil,
          memory: Jidoka.Memory.config() | nil,
          output: Jidoka.Output.t() | nil,
          skills: Jidoka.Skill.config() | nil,
          mcp_tools: Jidoka.MCP.config()
        }

  @schema Zoi.object(%{
            hooks: Zoi.any(),
            context: Zoi.any() |> Zoi.default(%{}),
            guardrails: Zoi.any(),
            timeouts: Zoi.any() |> Zoi.default(Jidoka.Lifecycle.Timeouts.default()),
            compaction: Zoi.any() |> Zoi.optional(),
            memory: Zoi.any() |> Zoi.optional(),
            output: Zoi.any() |> Zoi.optional(),
            skills: Zoi.any() |> Zoi.optional(),
            mcp_tools: Zoi.any() |> Zoi.default([])
          })

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    with {:ok, parsed} <- Zoi.parse(@schema, attrs),
         {:ok, timeouts} <- Jidoka.Lifecycle.Timeouts.normalize(parsed.timeouts),
         :ok <- validate_context(parsed.context) do
      {:ok, struct(__MODULE__, %{parsed | timeouts: timeouts})}
    end
  end

  def new(other), do: {:error, {:invalid_lifecycle_config, other}}

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "invalid Jidoka lifecycle config: #{inspect(reason)}"
    end
  end

  defp validate_context(context) when is_map(context), do: :ok
  defp validate_context(context), do: {:error, {:invalid_lifecycle_context, context}}
end
