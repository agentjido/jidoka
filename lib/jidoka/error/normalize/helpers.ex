defmodule Jidoka.Error.Normalize.Helpers do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Error.{ConfigError, ExecutionError, ValidationError}

  @spec validation_error(String.t(), keyword() | map()) :: Exception.t()
  def validation_error(message, details), do: ValidationError.exception(error_opts(details, message))

  @spec config_error(String.t(), keyword() | map()) :: Exception.t()
  def config_error(message, details), do: ConfigError.exception(error_opts(details, message))

  @spec execution_error(String.t(), keyword() | map()) :: Exception.t()
  def execution_error(message, details), do: ExecutionError.exception(error_opts(details, message))

  @spec control_name(term()) :: String.t()
  def control_name(control) when is_atom(control) do
    case Jidoka.Control.control_name(control) do
      {:ok, name} -> name
      {:error, _reason} -> inspect(control)
    end
  end

  def control_name(control), do: inspect(control)

  @spec effect_operation_name(Effect.Intent.t()) :: String.t() | nil
  def effect_operation_name(%Effect.Intent{kind: :operation, payload: payload}) do
    Map.get(payload, :name) || Map.get(payload, "name")
  end

  def effect_operation_name(_intent), do: nil

  @spec details(keyword() | map(), map()) :: map()
  def details(context, attrs) do
    context
    |> to_context_map()
    |> Map.take([:operation, :phase, :agent_id, :request_id, :target, :intent_id, :effect_kind])
    |> Map.merge(attrs)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @spec detail(keyword() | map(), atom(), term()) :: term()
  def detail(context, key, default \\ nil)
  def detail(context, key, default) when is_map(context), do: Map.get(context, key, default)
  def detail(context, key, default) when is_list(context), do: Keyword.get(context, key, default)
  def detail(_context, _key, default), do: default

  defp error_opts(details, message) when is_map(details) do
    details
    |> Map.put(:message, message)
    |> Map.put_new(:details, %{})
  end

  defp error_opts(details, message) when is_list(details) do
    details
    |> Keyword.put(:message, message)
    |> Keyword.put_new(:details, %{})
  end

  defp to_context_map(context) when is_map(context), do: context
  defp to_context_map(context) when is_list(context), do: Map.new(context)
  defp to_context_map(_context), do: %{}
end
