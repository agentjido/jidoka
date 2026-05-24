defmodule Jidoka.Control do
  @moduledoc """
  Defines reusable policy controls for Jidoka agents.

  Controls are small modules that decide whether an input, operation, or final
  result may continue.

  Return values:

  - `:cont` or `:ok` to continue
  - `{:block, reason}` to stop intentionally with a policy failure
  - `{:interrupt, interrupt}` to pause for approval or outside input
  - `{:error, reason}` for an unexpected control failure

  Controls run in declaration order within their stage. The first `:cont` or
  `:ok` result allows the next control to run. The first `{:block, reason}`,
  `{:interrupt, interrupt}`, or `{:error, reason}` result short-circuits the
  stage and prevents later controls in that stage from running.
  """

  @type name :: String.t()
  @type decision ::
          :cont
          | :ok
          | {:block, term()}
          | {:interrupt, term()}
          | {:error, term()}

  @callback name() :: name()
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

  @doc false
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
