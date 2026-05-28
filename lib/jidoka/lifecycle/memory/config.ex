defmodule Jidoka.Memory.Config do
  @moduledoc false

  @default_retrieve_limit 5
  @default_config %{
    mode: :conversation,
    namespace: :per_agent,
    capture: :conversation,
    retrieve: %{limit: @default_retrieve_limit},
    inject: :instructions
  }

  @spec default_config() :: Jidoka.Memory.config()
  def default_config, do: @default_config

  @spec normalize_imported(nil | map()) :: {:ok, Jidoka.Memory.config() | nil} | {:error, String.t()}
  def normalize_imported(nil), do: {:ok, nil}

  def normalize_imported(%{} = memory) do
    attrs =
      memory
      |> normalize_imported_namespace()
      |> Map.put(:mode, imported_atom(get_value(memory, :mode, @default_config.mode)))
      |> Map.put(:capture, imported_atom(get_value(memory, :capture, @default_config.capture)))
      |> Map.put(:inject, imported_atom(get_value(memory, :inject, @default_config.inject)))
      |> Map.put(
        :retrieve,
        memory
        |> get_value(:retrieve, %{})
        |> normalize_imported_retrieve()
      )

    normalize_map(attrs)
  end

  def normalize_imported(other),
    do: {:error, "memory must be a map, got: #{inspect(other)}"}

  @spec default_plugins(Jidoka.Memory.config() | nil) :: map()
  def default_plugins(nil), do: %{__memory__: false}

  def default_plugins(%{} = config) do
    %{__memory__: {Jido.Memory.BasicPlugin, plugin_config(config)}}
  end

  defp normalize_map(attrs) when is_map(attrs) do
    mode = Map.get(attrs, :mode, @default_config.mode)
    namespace = Map.get(attrs, :namespace, @default_config.namespace)
    shared_namespace = Map.get(attrs, :shared_namespace)
    capture = Map.get(attrs, :capture, @default_config.capture)
    inject = Map.get(attrs, :inject, @default_config.inject)
    retrieve = Map.get(attrs, :retrieve, @default_config.retrieve)

    with :ok <- validate_mode(mode),
         {:ok, namespace} <- validate_namespace(namespace, shared_namespace),
         :ok <- validate_capture(capture),
         :ok <- validate_inject(inject),
         {:ok, retrieve} <- normalize_retrieve(retrieve) do
      {:ok,
       %{
         mode: :conversation,
         namespace: namespace,
         capture: capture,
         retrieve: retrieve,
         inject: inject
       }}
    end
  end

  defp validate_mode(:conversation), do: :ok

  defp validate_mode(other),
    do: {:error, "memory mode must be :conversation, got: #{inspect(other)}"}

  defp validate_namespace(:per_agent, nil), do: {:ok, :per_agent}

  defp validate_namespace(:per_agent, shared_namespace) do
    {:error, "memory shared_namespace is only valid when namespace is :shared, got: #{inspect(shared_namespace)}"}
  end

  defp validate_namespace(:shared, shared_namespace) do
    with :ok <- validate_shared_namespace_for_namespace(shared_namespace) do
      {:ok, {:shared, String.trim(shared_namespace)}}
    end
  end

  defp validate_namespace({:context, key}, nil) do
    if valid_namespace_key?(key) do
      {:ok, {:context, key}}
    else
      {:error, "memory namespace must be :per_agent, :shared, or {:context, key}, got: #{inspect({:context, key})}"}
    end
  end

  defp validate_namespace({:context, _key}, shared_namespace) do
    {:error, "memory shared_namespace is only valid when namespace is :shared, got: #{inspect(shared_namespace)}"}
  end

  defp validate_namespace(other, _shared_namespace) do
    {:error,
     "memory namespace must be :per_agent, :shared with shared_namespace, or {:context, key}, got: #{inspect(other)}"}
  end

  defp valid_namespace_key?(key) when is_atom(key), do: not is_nil(key)

  defp valid_namespace_key?(key) when is_binary(key) do
    String.trim(key) != ""
  end

  defp valid_namespace_key?(_key), do: false

  defp validate_shared_namespace(value) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, "memory shared_namespace must not be empty"}
    else
      :ok
    end
  end

  defp validate_shared_namespace(_),
    do: {:error, "memory shared_namespace must be a non-empty string"}

  defp validate_shared_namespace_for_namespace(value) do
    case validate_shared_namespace(value) do
      :ok ->
        :ok

      {:error, _reason} ->
        {:error, "memory namespace must be :per_agent, :shared with shared_namespace, or {:context, key}, got: :shared"}
    end
  end

  defp validate_capture(:conversation), do: :ok
  defp validate_capture(:off), do: :ok

  defp validate_capture(other),
    do: {:error, "memory capture must be :conversation or :off, got: #{inspect(other)}"}

  defp validate_inject(:instructions), do: :ok
  defp validate_inject(:context), do: :ok

  defp validate_inject(other),
    do: {:error, "memory inject must be :instructions or :context, got: #{inspect(other)}"}

  defp normalize_retrieve(%{limit: limit}),
    do: with(:ok <- validate_limit(limit), do: {:ok, %{limit: limit}})

  defp normalize_retrieve(limit) when is_integer(limit), do: normalize_retrieve(%{limit: limit})
  defp normalize_retrieve(_), do: {:ok, %{limit: @default_retrieve_limit}}

  defp validate_limit(limit) when is_integer(limit) and limit > 0, do: :ok

  defp validate_limit(other),
    do: {:error, "memory retrieve limit must be a positive integer, got: #{inspect(other)}"}

  defp normalize_imported_namespace(memory) do
    case get_value(memory, :namespace, "per_agent") do
      "per_agent" ->
        %{namespace: :per_agent}

      :per_agent ->
        %{namespace: :per_agent}

      "shared" ->
        %{namespace: :shared, shared_namespace: get_value(memory, :shared_namespace)}

      :shared ->
        %{namespace: :shared, shared_namespace: get_value(memory, :shared_namespace)}

      "context" ->
        %{namespace: {:context, get_value(memory, :context_namespace_key)}}

      :context ->
        %{namespace: {:context, get_value(memory, :context_namespace_key)}}

      other ->
        %{namespace: other}
    end
  end

  defp normalize_imported_retrieve(%{} = retrieve) do
    %{limit: get_value(retrieve, :limit, @default_retrieve_limit)}
  end

  defp normalize_imported_retrieve(_), do: %{limit: @default_retrieve_limit}

  defp plugin_config(%{namespace: :per_agent}) do
    %{
      store: {Jido.Memory.Store.ETS, [table: :jidoka_memory]},
      store_opts: [],
      namespace_mode: :per_agent,
      auto_capture: false
    }
  end

  defp plugin_config(%{namespace: {:shared, shared_namespace}}) do
    %{
      store: {Jido.Memory.Store.ETS, [table: :jidoka_memory]},
      store_opts: [],
      namespace_mode: :shared,
      shared_namespace: shared_namespace,
      auto_capture: false
    }
  end

  defp plugin_config(%{namespace: {:context, _key}}) do
    %{
      store: {Jido.Memory.Store.ETS, [table: :jidoka_memory]},
      store_opts: [],
      namespace_mode: :per_agent,
      auto_capture: false
    }
  end

  defp get_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, normalize_lookup_key(key), default))
  end

  defp imported_atom(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      "conversation" -> :conversation
      "off" -> :off
      "instructions" -> :instructions
      "context" -> :context
      normalized -> normalized
    end
  end

  defp imported_atom(value), do: value

  defp normalize_lookup_key(key) when is_atom(key), do: Atom.to_string(key)
end
