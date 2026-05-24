defmodule Jidoka.StageRefs do
  @moduledoc false

  @type stage :: atom()
  @type ref :: module() | {module(), atom(), [term()]} | (term() -> term())
  @type stage_map :: %{required(stage()) => [ref()]}

  @spec default_stage_map([stage()]) :: stage_map()
  def default_stage_map(stages) when is_list(stages) do
    Map.new(stages, &{&1, []})
  end

  @spec combine([stage()], stage_map(), stage_map()) :: stage_map()
  def combine(stages, defaults, request_refs) when is_list(stages) do
    Map.new(stages, fn stage ->
      {stage, Map.get(defaults, stage, []) ++ Map.get(request_refs, stage, [])}
    end)
  end

  @spec normalize_dsl(stage_map(), keyword()) :: {:ok, stage_map()} | {:error, term()}
  def normalize_dsl(stage_map, opts) when is_map(stage_map) and is_list(opts) do
    stages = Keyword.fetch!(opts, :stages)

    Enum.reduce_while(stages, {:ok, default_stage_map(stages)}, fn stage, {:ok, acc} ->
      case normalize_stage_list(Map.get(stage_map, stage, []), stage, :dsl, opts) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, stage, normalized)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec normalize_request(term(), keyword()) :: {:ok, stage_map()} | {:error, term()}
  def normalize_request(nil, opts) when is_list(opts) do
    {:ok, default_stage_map(Keyword.fetch!(opts, :stages))}
  end

  def normalize_request(refs, opts) when (is_list(refs) or is_map(refs)) and is_list(opts) do
    case Jidoka.Context.coerce_map(refs) do
      {:ok, normalized} ->
        normalize_stage_map(normalized, :runtime, opts)

      :error ->
        {:error, invalid_spec(refs, opts)}
    end
  end

  def normalize_request(other, opts) when is_list(opts) do
    {:error, invalid_spec(other, opts)}
  end

  @spec validate_dsl_ref(stage(), term(), keyword()) :: :ok | {:error, term()}
  def validate_dsl_ref(stage, ref, opts) when is_list(opts) do
    case normalize_stage_ref(ref, stage, :dsl, opts) do
      {:ok, _ref} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_stage_map(refs, mode, opts) do
    stages = Keyword.fetch!(opts, :stages)

    Enum.reduce_while(Map.to_list(refs), {:ok, default_stage_map(stages)}, fn {key, value}, {:ok, acc} ->
      with {:ok, stage} <- normalize_stage_key(key, opts),
           {:ok, normalized} <- normalize_stage_list(value, stage, mode, opts) do
        {:cont, {:ok, Map.put(acc, stage, normalized)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_stage_key(stage, opts) do
    stages = Keyword.fetch!(opts, :stages)

    cond do
      stage in stages ->
        {:ok, stage}

      is_binary(stage) ->
        normalize_binary_stage(stage, stages, opts)

      true ->
        {:error, invalid_stage(stage, opts)}
    end
  end

  defp normalize_binary_stage(stage, stages, opts) do
    try do
      stage_atom = String.to_existing_atom(stage)

      if stage_atom in stages do
        {:ok, stage_atom}
      else
        {:error, invalid_stage(stage_atom, opts)}
      end
    rescue
      ArgumentError -> {:error, invalid_stage(stage, opts)}
    end
  end

  defp normalize_stage_list(value, stage, mode, opts) do
    value
    |> refs_from_value()
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
      case normalize_stage_ref(ref, stage, mode, opts) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, wrap_invalid_ref(stage, reason, opts)}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp refs_from_value(value) do
    cond do
      value == [] -> []
      is_list(value) and not Keyword.keyword?(value) -> value
      value == nil -> []
      true -> [value]
    end
  end

  defp normalize_stage_ref(module, _stage, _mode, opts) when is_atom(module) do
    case Keyword.fetch!(opts, :module_validator).(module) do
      :ok -> {:ok, module}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_stage_ref(%Jidoka.Control.Operation{ref: ref} = operation, :tool, mode, opts) do
    case normalize_stage_ref(ref, :tool, mode, opts) do
      {:ok, normalized_ref} -> {:ok, %{operation | ref: normalized_ref}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_stage_ref({module, function, args} = ref, _stage, _mode, opts)
       when is_atom(module) and is_atom(function) and is_list(args) do
    label = Keyword.fetch!(opts, :ref_label)

    case Code.ensure_compiled(module) do
      {:module, ^module} ->
        arity = length(args) + 1

        if function_exported?(module, function, arity) do
          {:ok, ref}
        else
          {:error, "#{label} MFA #{inspect(ref)} must export #{function}/#{arity} on #{inspect(module)}"}
        end

      {:error, reason} ->
        {:error, "#{label} module #{inspect(module)} could not be loaded: #{inspect(reason)}"}
    end
  end

  defp normalize_stage_ref(fun, _stage, :runtime, _opts) when is_function(fun, 1),
    do: {:ok, fun}

  defp normalize_stage_ref(fun, _stage, :dsl, opts) when is_function(fun) do
    {:error, Keyword.fetch!(opts, :dsl_function_error)}
  end

  defp normalize_stage_ref(other, _stage, _mode, opts) do
    {:error, Keyword.fetch!(opts, :invalid_ref_message).(other)}
  end

  defp invalid_stage(stage, opts), do: {Keyword.fetch!(opts, :invalid_stage), stage}

  defp invalid_spec(value, opts) do
    tag = Keyword.fetch!(opts, :invalid_spec)
    label = Keyword.fetch!(opts, :spec_label)

    {tag, "#{label} must be a keyword list or map, got: #{inspect(value)}"}
  end

  defp wrap_invalid_ref(stage, reason, opts) when is_binary(reason),
    do: {Keyword.fetch!(opts, :invalid_ref), stage, reason}

  defp wrap_invalid_ref(stage, reason, opts),
    do: {Keyword.fetch!(opts, :invalid_ref), stage, inspect(reason)}
end
