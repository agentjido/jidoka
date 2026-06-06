defmodule Jidoka.Operation.Source.MCP.Transport do
  @moduledoc false

  alias Jidoka.Schema

  @transport_layers [:stdio, :shell, :sse, :streamable_http]
  @transport_option_keys [
    :command,
    :args,
    :env,
    :cwd,
    :base_url,
    :base_path,
    :sse_path,
    :headers,
    :method,
    :url
  ]

  @spec normalize(term()) :: {:ok, term()} | {:error, term()}
  def normalize(nil), do: {:ok, nil}

  def normalize({layer, opts} = transport)
      when layer in @transport_layers and is_list(opts),
      do: {:ok, transport}

  def normalize(%{} = transport) do
    with {:ok, layer} <-
           normalize_transport_layer(
             Schema.get_key(transport, :type) ||
               Schema.get_key(transport, :layer) ||
               Schema.get_key(transport, :transport)
           ),
         {:ok, opts} <-
           normalize_transport_opts(Map.drop(transport, [:type, "type", :layer, "layer", :transport, "transport"])) do
      {:ok, {layer, opts}}
    end
  end

  def normalize(transport), do: {:error, {:invalid_mcp_transport, transport}}

  @spec endpoint(struct()) :: {:ok, term()} | {:error, term()}
  def endpoint(source) do
    Jido.MCP.Endpoint.new(source.endpoint, %{
      transport: source.transport,
      client_info: source.client_info,
      protocol_version: source.protocol_version,
      capabilities: source.capabilities,
      timeouts: source.timeouts
    })
  end

  def call_opts(source) do
    []
    |> maybe_put_timeout(source.timeout)
    |> maybe_put_timeouts(source.timeouts)
  end

  defp normalize_transport_layer(layer) when layer in @transport_layers, do: {:ok, layer}

  defp normalize_transport_layer(layer) when is_binary(layer) do
    layer = layer |> String.trim() |> String.downcase()

    @transport_layers
    |> Enum.find(&(Atom.to_string(&1) == layer))
    |> case do
      nil -> {:error, {:invalid_mcp_transport_layer, layer}}
      layer -> {:ok, layer}
    end
  end

  defp normalize_transport_layer(layer), do: {:error, {:invalid_mcp_transport_layer, layer}}

  defp normalize_transport_opts(opts) when is_map(opts) do
    opts
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      case normalize_transport_option_key(key) do
        {:ok, key} -> {:cont, {:ok, [{key, value} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, opts} -> {:ok, Enum.reverse(opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_transport_option_key(key) when key in @transport_option_keys, do: {:ok, key}

  defp normalize_transport_option_key(key) when is_binary(key) do
    @transport_option_keys
    |> Enum.find(&(Atom.to_string(&1) == key))
    |> case do
      nil -> {:error, {:invalid_mcp_transport_option, key}}
      key -> {:ok, key}
    end
  end

  defp normalize_transport_option_key(key), do: {:error, {:invalid_mcp_transport_option, key}}

  defp maybe_put_timeout(opts, nil), do: opts
  defp maybe_put_timeout(opts, timeout), do: Keyword.put(opts, :timeout, timeout)

  defp maybe_put_timeouts(opts, timeouts) when timeouts in [nil, %{}], do: opts
  defp maybe_put_timeouts(opts, timeouts), do: Keyword.put(opts, :timeouts, timeouts)
end
