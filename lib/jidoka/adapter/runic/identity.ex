defmodule Jidoka.Adapter.Runic.Identity do
  @moduledoc false

  @doc false
  @spec project(term()) :: term()
  def project(value) do
    value
    |> Jidoka.Portable.project()
    |> drop_runtime_values()
  end

  defp drop_runtime_values(value)
       when is_function(value) or is_pid(value) or is_port(value) or is_reference(value),
       do: :jidoka_runtime_value

  defp drop_runtime_values(%{} = map) do
    Map.new(map, fn {key, value} -> {key, drop_runtime_values(value)} end)
  end

  defp drop_runtime_values(list) when is_list(list), do: Enum.map(list, &drop_runtime_values/1)

  defp drop_runtime_values(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&drop_runtime_values/1)
    |> List.to_tuple()
  end

  defp drop_runtime_values(value), do: value
end

if Code.ensure_loaded?(Runic.Identity.Projectable) do
  defimpl Runic.Identity.Projectable, for: Jidoka.Turn.State do
    def identity_document(state) do
      state
      |> Jidoka.Projection.Turn.project()
      |> Jidoka.Adapter.Runic.Identity.project()
    end
  end

  defimpl Runic.Identity.Projectable, for: Jidoka.Workflow.Spec do
    def identity_document(spec), do: Jidoka.Projection.Workflow.project(spec)
  end

  defimpl Runic.Identity.Projectable, for: Jidoka.Workflow.Step do
    def identity_document(step), do: Jidoka.Projection.Workflow.project(step)
  end

  defimpl Runic.Identity.Projectable, for: Jidoka.Context do
    def identity_document(context) do
      context
      |> Jidoka.Context.data()
      |> Jidoka.Adapter.Runic.Identity.project()
    end
  end

  defimpl Runic.Identity.Projectable, for: Jido.Action.Catalog.Entry do
    def identity_document(entry) do
      entry
      |> Map.from_struct()
      |> Jidoka.Adapter.Runic.Identity.project()
    end
  end

  defimpl Runic.Identity.Projectable, for: Jidoka.Workflow.Loop.Result do
    def identity_document(result) do
      result
      |> Map.from_struct()
      |> Jidoka.Adapter.Runic.Identity.project()
    end
  end

  defimpl Runic.Identity.Projectable, for: Jidoka.Effect.Result do
    def identity_document(result) do
      result
      |> Map.from_struct()
      |> Jidoka.Adapter.Runic.Identity.project()
    end
  end

  defimpl Runic.Identity.Projectable, for: Jidoka.Operation.Continuation do
    def identity_document(continuation) do
      continuation
      |> Map.from_struct()
      |> Jidoka.Adapter.Runic.Identity.project()
    end
  end

  defimpl Runic.Identity.Projectable, for: Jidoka.Workflow.Loop.Cursor do
    def identity_document(cursor) do
      cursor
      |> Map.from_struct()
      |> Jidoka.Adapter.Runic.Identity.project()
    end
  end

  for error <- [
        Jidoka.Error.ValidationError,
        Jidoka.Error.ConfigError,
        Jidoka.Error.ExecutionError,
        RuntimeError
      ] do
    defimpl Runic.Identity.Projectable, for: error do
      def identity_document(error), do: Jidoka.Adapter.Runic.Identity.project(error)
    end
  end
end
