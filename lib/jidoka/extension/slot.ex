defmodule Jidoka.Extension.Slot do
  @moduledoc "Live runtime slots returned by a trusted extension factory."

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Extension.Identity

  @keys ~w(namespace tools tool_handlers commands providers policy_advice context lifecycle checkpoint close state result)a
  @enforce_keys [:namespace]
  defstruct namespace: nil,
            tools: [],
            tool_handlers: %{},
            commands: %{},
            providers: %{},
            policy_advice: nil,
            context: nil,
            lifecycle: nil,
            checkpoint: nil,
            close: nil,
            state: %{},
            result: %{}

  @type t :: %__MODULE__{
          namespace: String.t(),
          tools: [Operation.t()],
          tool_handlers: map(),
          commands: map(),
          providers: map(),
          policy_advice: function() | nil,
          context: function() | nil,
          lifecycle: function() | nil,
          checkpoint: function() | nil,
          close: function() | nil,
          state: map(),
          result: map()
        }

  @doc "Builds and validates live extension slots and portable initial data."
  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = slot), do: validate(slot)

  def new(attrs) do
    attrs = attrs |> Jidoka.Schema.normalize_attrs() |> normalize_keys()

    case unknown_keys(attrs) do
      [] -> attrs |> then(&struct(__MODULE__, Map.take(&1, @keys))) |> validate()
      keys -> {:error, {:unknown_extension_slots, keys}}
    end
  end

  @doc "Builds slots or raises."
  @spec new!(t() | keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, slot} -> slot
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  defp validate(slot) do
    with true <- Identity.valid_id?(slot.namespace),
         true <- Enum.all?(slot.tools, &match?(%Operation{}, &1)),
         true <- handlers?(slot.tool_handlers),
         true <- handlers?(slot.commands),
         true <- handlers?(slot.providers),
         true <- optional_function?(slot.policy_advice),
         true <- optional_function?(slot.context),
         true <- optional_function?(slot.lifecycle),
         true <- optional_function?(slot.checkpoint),
         true <- optional_function?(slot.close),
         :ok <- Contract.validate_safe_map(slot.state),
         :ok <- Contract.validate_safe_map(slot.result) do
      {:ok, slot}
    else
      reason -> {:error, {:invalid_extension_slots, reason}}
    end
  end

  defp unknown_keys(attrs) do
    Map.keys(attrs) -- @keys
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    Enum.find(@keys, key, &(Atom.to_string(&1) == key))
  end

  defp normalize_key(key), do: key

  defp handlers?(value), do: is_map(value) and Enum.all?(value, fn {_name, handler} -> is_function(handler) end)
  defp optional_function?(nil), do: true
  defp optional_function?(value), do: is_function(value)
end
