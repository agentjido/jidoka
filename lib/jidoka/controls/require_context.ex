defmodule Jidoka.Controls.RequireContext do
  @moduledoc """
  Built-in control that requires application context keys to be present.

  Configure with `metadata: %{keys: [:tenant_id, :user_id]}` on an input,
  operation, or output control.
  """

  use Jidoka.Control, name: "require_context"

  @impl true
  def call(context) do
    with {:ok, ctx} <- runtime_context(context),
         {:ok, keys} <- required_keys(context) do
      missing = Enum.reject(keys, &context_key_present?(ctx, &1))

      case missing do
        [] -> :cont
        missing -> {:block, {:missing_context_keys, missing}}
      end
    end
  end

  defp runtime_context(%{ctx: %Jidoka.Context{} = ctx}), do: {:ok, ctx}
  defp runtime_context(%Jidoka.Context{} = ctx), do: {:ok, ctx}
  defp runtime_context(_context), do: {:error, :missing_jidoka_context}

  defp required_keys(%{metadata: metadata}), do: required_keys(metadata)

  defp required_keys(metadata) when is_map(metadata) do
    metadata
    |> get_any([:keys, "keys", :required, "required"])
    |> normalize_keys()
  end

  defp required_keys(_metadata), do: {:error, :missing_required_context_keys}

  defp normalize_keys(nil), do: {:error, :missing_required_context_keys}

  defp normalize_keys(keys) when is_list(keys) do
    keys
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
      case normalize_key(key) do
        {:ok, key} -> {:cont, {:ok, [key | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, Enum.reverse(keys)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_keys(key), do: normalize_keys([key])

  defp normalize_key(key) when is_atom(key) and not is_nil(key), do: {:ok, Atom.to_string(key)}

  defp normalize_key(key) when is_binary(key) do
    case String.trim(key) do
      "" -> {:error, {:invalid_context_key, key}}
      key -> {:ok, key}
    end
  end

  defp normalize_key(key), do: {:error, {:invalid_context_key, key}}

  defp context_key_present?(%Jidoka.Context{} = ctx, key) do
    case Jidoka.Context.fetch(ctx, key) do
      {:ok, nil} -> false
      {:ok, _value} -> true
      :error -> false
    end
  end

  defp get_any(map, keys), do: Enum.find_value(keys, &Map.get(map, &1))
end
