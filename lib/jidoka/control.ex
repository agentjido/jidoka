defmodule Jidoka.Control do
  @moduledoc """
  Defines reusable policy controls for Jidoka agents.

  Controls are small modules that decide whether an input, operation, or final
  result may continue.

  Return values:

  - `:allow`, `:cont`, or `:ok` to continue
  - `{:transform, updates}` to continue with an updated input/result control
    struct or a map/keyword of fields to update
  - `{:block, reason}` to stop intentionally with a policy failure
  - `{:interrupt, interrupt}` to pause for approval or outside input
  - `{:error, reason}` for an unexpected control failure

  Controls run in declaration order within their stage. Allow and transform
  results allow the next control to run. The first `{:block, reason}`,
  `{:interrupt, interrupt}`, `{:error, reason}`, or invalid transform result
  short-circuits the stage and prevents later controls in that stage from
  running.

  Placement in the agent loop:

  - input controls run after lifecycle preparation and before the provider call
  - operation controls run immediately before an action, workflow, subagent, or
    handoff operation executes
  - result controls run after typed result parsing/repair and before the caller
    receives the final value
  - scheduled turns call the normal chat path, so they run the same controls
  - provider/tool retries do not retry blocked or interrupted controls; a
    control block, interrupt, or error ends the current turn
  """

  @type name :: String.t()
  @type decision ::
          :cont
          | :ok
          | :allow
          | {:transform, struct() | map() | keyword()}
          | {:block, term()}
          | {:interrupt, term()}
          | {:error, term()}

  @doc """
  Returns the stable published name for the control.
  """
  @callback name() :: name()

  @doc """
  Evaluates the control for the current input, operation, or result.
  """
  @callback call(term()) :: decision()

  @doc """
  Defines a reusable Jidoka control module.
  """
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts \\ []) do
    module_name =
      __CALLER__.module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    defaults = [
      name: module_name
    ]

    quote location: :keep do
      @behaviour Jidoka.Control

      @control_name unquote(Keyword.get(Keyword.merge(defaults, opts), :name))

      @spec name() :: String.t()
      def name, do: @control_name

      @after_compile Jidoka.Control
    end
  end

  @doc """
  Validates the control module contract after compilation.
  """
  @spec __after_compile__(Macro.Env.t(), binary()) :: :ok | no_return()
  def __after_compile__(env, _bytecode) do
    case validate_control_module(env.module) do
      :ok ->
        :ok

      {:error, message} ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: message
    end
  end

  @doc """
  Validates that a module implements the Jidoka control contract.
  """
  @spec validate_control_module(module()) :: :ok | {:error, String.t()}
  def validate_control_module(module) do
    case Jidoka.Guardrail.validate_guardrail_module(module) do
      :ok -> :ok
      {:error, message} -> {:error, control_message(message)}
    end
  end

  @doc """
  Returns the published name for a validated control module.
  """
  @spec control_name(module()) :: {:ok, name()} | {:error, String.t()}
  def control_name(module) do
    case Jidoka.Guardrail.guardrail_name(module) do
      {:ok, name} -> {:ok, name}
      {:error, message} -> {:error, control_message(message)}
    end
  end

  defp control_message(message) when is_binary(message) do
    String.replace(message, "guardrail", "control")
  end
end

defmodule Jidoka.Control.Operation do
  @moduledoc false

  @enforce_keys [:ref]
  defstruct [:ref, :match]

  @type t :: %__MODULE__{
          ref: Jidoka.Guardrails.guardrail_ref(),
          match: map() | nil
        }
end
