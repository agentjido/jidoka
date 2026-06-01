defmodule Jidoka.Control do
  @moduledoc """
  Minimal reusable policy control contract for Jidoka agents.

  Controls are declared by agents as data first. Runtime execution will attach
  them at explicit control points, but the first V2 slice only needs a stable
  module contract and published name.
  """

  @type name :: String.t()
  @type decision ::
          :allow
          | :cont
          | :ok
          | {:block, term()}
          | {:interrupt, term()}
          | {:error, term()}

  @doc "Returns the stable control name used in specs, traces, and inspection output."
  @callback name() :: name()

  @doc "Evaluates a control context and returns whether execution may continue."
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

    control_name = Keyword.get(opts, :name, module_name)

    quote location: :keep do
      @behaviour Jidoka.Control

      @doc false
      @spec name() :: String.t()
      def name, do: unquote(control_name)

      defoverridable name: 0
    end
  end

  @doc """
  Validates that a module implements the Jidoka control contract.
  """
  @spec validate_module(module()) :: :ok | {:error, String.t()}
  def validate_module(module) when is_atom(module) and not is_nil(module) do
    case Code.ensure_compiled(module) do
      {:module, _module} ->
        validate_compiled_module(module)

      {:error, reason} ->
        {:error, "could not compile control #{inspect(module)}: #{inspect(reason)}"}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  def validate_module(module), do: {:error, "invalid control module: #{inspect(module)}"}

  defp validate_compiled_module(module) do
    if function_exported?(module, :name, 0) and function_exported?(module, :call, 1) do
      case control_name(module) do
        {:ok, _name} -> :ok
        {:error, message} -> {:error, message}
      end
    else
      {:error, "#{inspect(module)} must expose `name/0` and `call/1`"}
    end
  end

  @doc """
  Returns the published name for a validated control module.
  """
  @spec control_name(module()) :: {:ok, name()} | {:error, String.t()}
  def control_name(module) when is_atom(module) and not is_nil(module) do
    name = module.name()

    if is_binary(name) and String.trim(name) != "" do
      {:ok, String.trim(name)}
    else
      {:error, "#{inspect(module)}.name/0 must return a non-empty string"}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end
end
