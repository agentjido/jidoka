defmodule Jidoka.Action do
  @moduledoc """
  Defines deterministic actions that a Jidoka agent may call.

  `Jidoka.Action` is the user-facing wrapper around `Jido.Action`. It keeps
  authoring focused on deterministic application operations while Jidoka handles
  the provider-facing operation metadata at runtime.

  Actions are Zoi-first and Zoi-only for schema authoring. If an action defines
  `schema` or `output_schema`, they must resolve to Zoi schemas.

      defmodule MyApp.Actions.AddNumbers do
        use Jidoka.Action,
          description: "Adds two integers together.",
          schema: Zoi.object(%{a: Zoi.integer(), b: Zoi.integer()})

        @impl true
        def run(%{a: a, b: b}, _context) do
          {:ok, %{sum: a + b}}
        end
      end
  """

  @type name :: String.t()
  @type registry :: %{required(name()) => module()}

  @doc """
  Defines a deterministic Jidoka action backed by `Jido.Action`.
  """
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts \\ []) do
    quote location: :keep do
      use Jidoka.Action.Adapter, unquote(opts)
    end
  end

  @doc """
  Validates that a module behaves like an action-backed module.
  """
  @spec validate_module(module()) :: :ok | {:error, String.t()}
  defdelegate validate_module(module), to: Jidoka.Action.Adapter, as: :validate_tool_module

  @doc """
  Validates that a module behaves like a generic Jido action.
  """
  @spec validate_action_module(module()) :: :ok | {:error, String.t()}
  defdelegate validate_action_module(module), to: Jidoka.Action.Adapter

  @doc """
  Returns the published action name for a validated action module.
  """
  @spec name(module()) :: {:ok, name()} | {:error, String.t()}
  defdelegate name(module), to: Jidoka.Action.Adapter, as: :tool_name

  @doc """
  Returns the published action names for validated action modules.
  """
  @spec names([module()]) :: {:ok, [name()]} | {:error, String.t()}
  defdelegate names(modules), to: Jidoka.Action.Adapter, as: :tool_names

  @doc """
  Normalizes an available action registry for imported agent specs.
  """
  @spec normalize_registry([module()] | %{required(name()) => module()}) ::
          {:ok, registry()} | {:error, String.t()}
  defdelegate normalize_registry(actions), to: Jidoka.Action.Adapter, as: :normalize_available_tools

  @doc """
  Resolves published action names against a normalized action registry.
  """
  @spec resolve_names([name()], registry()) :: {:ok, [module()]} | {:error, String.t()}
  defdelegate resolve_names(names, registry), to: Jidoka.Action.Adapter, as: :resolve_tool_names
end
