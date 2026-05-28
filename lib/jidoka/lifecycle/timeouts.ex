defmodule Jidoka.Lifecycle.Timeouts do
  @moduledoc false

  @default_timeout_ms 5_000
  @hook_stages [:before_turn, :after_turn, :on_interrupt]
  @control_stages [:input, :output, :tool]

  @type hook_stage :: :before_turn | :after_turn | :on_interrupt
  @type control_stage :: :input | :output | :tool
  @type stage_map(stage) :: %{required(stage) => pos_integer()}
  @type t :: %{
          hooks: stage_map(hook_stage()),
          controls: stage_map(control_stage())
        }

  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @spec default() :: t()
  def default do
    %{
      hooks: stage_map(@hook_stages, @default_timeout_ms),
      controls: stage_map(@control_stages, @default_timeout_ms)
    }
  end

  @spec normalize(term()) :: {:ok, t()} | {:error, String.t()}
  def normalize(nil), do: {:ok, default()}

  def normalize(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      attrs
      |> Map.new()
      |> normalize()
    else
      {:error, "lifecycle timeouts must be a keyword list or map, got: #{inspect(attrs)}"}
    end
  end

  def normalize(%{} = attrs) do
    with :ok <- reject_unknown_keys(attrs, [:default, :hooks, :controls], "lifecycle timeouts"),
         {:ok, default_timeout} <- normalize_timeout(fetch(attrs, :default, @default_timeout_ms), :default),
         {:ok, hooks} <-
           normalize_stage_group(fetch(attrs, :hooks, nil), @hook_stages, default_timeout, :hooks),
         {:ok, controls} <-
           normalize_stage_group(fetch(attrs, :controls, nil), @control_stages, default_timeout, :controls) do
      {:ok, %{hooks: hooks, controls: controls}}
    end
  end

  def normalize(other), do: {:error, "lifecycle timeouts must be a keyword list or map, got: #{inspect(other)}"}

  @spec externalize(t()) :: map()
  def externalize(%{hooks: hooks, controls: controls}) do
    %{
      hooks: hooks,
      controls: %{
        input: controls.input,
        operation: controls.tool,
        result: controls.output
      }
    }
  end

  defp normalize_stage_group(nil, stages, default_timeout, _group) do
    {:ok, stage_map(stages, default_timeout)}
  end

  defp normalize_stage_group(timeout, stages, _default_timeout, group) when is_integer(timeout) do
    with {:ok, timeout} <- normalize_timeout(timeout, group) do
      {:ok, stage_map(stages, timeout)}
    end
  end

  defp normalize_stage_group(attrs, stages, default_timeout, group) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      attrs
      |> Map.new()
      |> normalize_stage_group(stages, default_timeout, group)
    else
      {:error, "#{group} timeouts must be a positive integer, keyword list, or map, got: #{inspect(attrs)}"}
    end
  end

  defp normalize_stage_group(%{} = attrs, stages, default_timeout, group) do
    Enum.reduce_while(attrs, {:ok, stage_map(stages, default_timeout)}, fn {key, value}, {:ok, acc} ->
      with {:ok, stage} <- normalize_stage_key(key, group),
           {:ok, timeout} <- normalize_timeout(value, "#{group}.#{stage}") do
        {:cont, {:ok, Map.put(acc, stage, timeout)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_stage_group(other, _stages, _default_timeout, group) do
    {:error, "#{group} timeouts must be a positive integer, keyword list, or map, got: #{inspect(other)}"}
  end

  defp normalize_timeout(timeout, _path) when is_integer(timeout) and timeout > 0, do: {:ok, timeout}

  defp normalize_timeout(timeout, path) do
    {:error, "#{path} timeout must be a positive integer in milliseconds, got: #{inspect(timeout)}"}
  end

  defp normalize_stage_key(stage, :hooks) when stage in @hook_stages, do: {:ok, stage}
  defp normalize_stage_key("before_turn", :hooks), do: {:ok, :before_turn}
  defp normalize_stage_key("after_turn", :hooks), do: {:ok, :after_turn}
  defp normalize_stage_key("on_interrupt", :hooks), do: {:ok, :on_interrupt}

  defp normalize_stage_key(stage, :controls) when stage in @control_stages, do: {:ok, stage}
  defp normalize_stage_key(:operation, :controls), do: {:ok, :tool}
  defp normalize_stage_key(:result, :controls), do: {:ok, :output}
  defp normalize_stage_key("input", :controls), do: {:ok, :input}
  defp normalize_stage_key("tool", :controls), do: {:ok, :tool}
  defp normalize_stage_key("output", :controls), do: {:ok, :output}
  defp normalize_stage_key("operation", :controls), do: {:ok, :tool}
  defp normalize_stage_key("result", :controls), do: {:ok, :output}

  defp normalize_stage_key(stage, group), do: {:error, "unknown #{group} timeout stage: #{inspect(stage)}"}

  defp reject_unknown_keys(attrs, allowed_keys, label) do
    unknown =
      attrs
      |> Map.keys()
      |> Enum.reject(&allowed_key?(&1, allowed_keys))

    case unknown do
      [] -> :ok
      _ -> {:error, "#{label} contain unknown keys: #{inspect(unknown)}"}
    end
  end

  defp allowed_key?(key, allowed) when is_atom(key), do: key in allowed

  defp allowed_key?(key, allowed) when is_binary(key) do
    Enum.any?(allowed, &(Atom.to_string(&1) == key))
  end

  defp allowed_key?(_key, _allowed), do: false

  defp fetch(map, key, default) do
    case {Map.fetch(map, key), Map.fetch(map, Atom.to_string(key))} do
      {{:ok, nil}, _} -> default
      {{:ok, value}, _} -> value
      {:error, {:ok, nil}} -> default
      {:error, {:ok, value}} -> value
      {:error, :error} -> default
    end
  end

  defp stage_map(stages, timeout), do: Map.new(stages, &{&1, timeout})
end
