defmodule Jidoka.Output do
  @moduledoc """
  Structured result contracts for Jidoka agents.

  The Jidoka DSL and beginner-facing docs call this concept `result`: the final
  app-facing value returned from a turn. This implementation module keeps the
  `Output` name because it owns parsing, validating, repairing, and finalizing
  raw model/provider output before the caller receives that result.
  """

  alias Jidoka.Lifecycle.PhaseSpec
  alias Jidoka.Output.{Config, Runtime, Schema}

  @type schema_kind :: :zoi | :json_schema
  @type validation_mode :: :repair | :error

  @type t :: %__MODULE__{
          schema: Zoi.schema() | map(),
          schema_kind: schema_kind(),
          retries: non_neg_integer(),
          on_validation_error: validation_mode()
        }

  defstruct [
    :schema,
    schema_kind: :zoi,
    retries: Config.default_retries(),
    on_validation_error: Config.default_on_validation_error()
  ]

  @doc false
  @spec context_key() :: atom()
  def context_key, do: Config.context_key()

  @doc """
  Builds a structured result contract from DSL/imported options.
  """
  @spec new(keyword() | map() | t() | nil) :: {:ok, t() | nil} | {:error, term()}
  def new(nil), do: {:ok, nil}
  def new(%__MODULE__{} = output), do: {:ok, output}

  def new(attrs) when is_list(attrs) or is_map(attrs) do
    with {:ok, attrs} <- Schema.normalize_attrs(attrs) do
      {:ok, struct(__MODULE__, attrs)}
    end
  end

  def new(other), do: {:error, "result contract must be a map or keyword list, got: #{inspect(other)}"}

  @doc """
  Validates a parsed result value against the configured schema.
  """
  @spec validate(t(), term()) :: {:ok, map()} | {:error, term()}
  def validate(%__MODULE__{} = output, value), do: Schema.validate(output, value)

  @doc """
  Parses and validates raw model/provider output into the app-facing result.
  """
  @spec parse(t(), term()) :: {:ok, map()} | {:error, term()}
  def parse(%__MODULE__{} = output, value), do: Schema.parse(output, value)

  @doc """
  Returns a prompt snippet that asks the model to produce the final result shape.
  """
  @spec instructions(t() | map() | nil) :: String.t() | nil
  def instructions(nil), do: nil
  def instructions(%__MODULE__{} = output), do: Schema.instructions(output)

  def instructions(context) when is_map(context) do
    context
    |> Runtime.runtime_output()
    |> Schema.instructions()
  end

  @doc """
  Converts a result contract to JSON Schema for provider repair calls and docs.
  """
  @spec json_schema(t()) :: map()
  def json_schema(%__MODULE__{} = output), do: Schema.json_schema(output)

  @doc false
  @spec on_before_cmd(Jido.Agent.t(), term(), t() | nil) :: {:ok, Jido.Agent.t(), term()}
  def on_before_cmd(agent, action, output), do: Runtime.on_before_cmd(agent, action, output)

  @doc false
  @spec on_after_cmd(Jido.Agent.t(), term(), [term()], t() | nil) :: {:ok, Jido.Agent.t(), [term()]}
  def on_after_cmd(agent, action, directives, output), do: Runtime.on_after_cmd(agent, action, directives, output)

  @doc false
  @spec before_phase_specs(t() | nil) :: [PhaseSpec.t()]
  def before_phase_specs(output) do
    [
      PhaseSpec.before(:output_before, :output, fn agent, action ->
        on_before_cmd(agent, action, output)
      end)
    ]
  end

  @doc false
  @spec after_phase_specs(t() | nil) :: [PhaseSpec.t()]
  def after_phase_specs(output) do
    [
      PhaseSpec.after_phase(:output_after, :output, fn agent, action, directives ->
        on_after_cmd(agent, action, directives, output)
      end)
    ]
  end

  @doc """
  Finalizes a completed request result into the structured app-facing result.
  """
  @spec finalize(Jido.Agent.t(), String.t(), t(), keyword()) :: Jido.Agent.t()
  def finalize(agent, request_id, %__MODULE__{} = output, opts \\ []) when is_binary(request_id) do
    Runtime.finalize(agent, request_id, output, opts)
  end

  @doc false
  @spec attach_request_option(map(), term()) :: map()
  def attach_request_option(context, option), do: Runtime.attach_request_option(context, option)

  @doc false
  @spec runtime_output(map()) :: t() | nil
  def runtime_output(context), do: Runtime.runtime_output(context)

  @doc false
  @spec imported_schema?(term()) :: boolean()
  def imported_schema?(schema), do: Schema.imported_schema?(schema)
end
