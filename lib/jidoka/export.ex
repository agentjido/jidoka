defmodule Jidoka.Export do
  @moduledoc """
  Portable JSON/YAML export for `Jidoka.Agent.Spec`.

  Export intentionally writes data, not executable Elixir values. Runtime-only
  values such as raw Zoi schemas must be represented by caller-owned registry
  refs when they need to round-trip through `Jidoka.import/2`.
  """

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Import.AgentDocument
  alias Jidoka.Turn

  @type format :: :json | :yaml
  @type option ::
          {:format, format()}
          | {:context_schema_ref, String.t() | atom()}
          | {:result_schema_ref, String.t() | atom()}
          | {:pretty, boolean()}

  @doc "Exports an agent, spec, or plan into a portable JSON/YAML document string."
  @spec export(module() | Spec.t() | Turn.Plan.t() | keyword() | map(), [option()]) ::
          {:ok, String.t()} | {:error, term()}
  def export(agent_input, opts \\ []) when is_list(opts) do
    with {:ok, format} <- normalize_format(Keyword.get(opts, :format, :json)),
         {:ok, spec} <- spec_from_input(agent_input),
         {:ok, document} <- document(spec, opts) do
      encode(document, format, opts)
    end
  end

  @doc "Builds the import-compatible document map without encoding it."
  @spec document(module() | Spec.t() | Turn.Plan.t() | keyword() | map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def document(agent_input, opts \\ []) do
    with {:ok, spec} <- spec_from_input(agent_input),
         {:ok, agent} <- agent_document(spec, opts),
         {:ok, controls} <- controls_document(spec.controls),
         {:ok, operations} <- operations_document(spec.operations) do
      document =
        %{
          "version" => AgentDocument.version(),
          "agent" => agent,
          "controls" => controls,
          "operations" => operations,
          "runtime_defaults" => portable_value(spec.runtime_defaults),
          "metadata" => export_metadata(spec.metadata)
        }
        |> reject_empty_values()

      {:ok, document}
    end
  end

  defp spec_from_input(%Spec{} = spec), do: Spec.from_input(spec)
  defp spec_from_input(%Turn.Plan{spec: %Spec{} = spec}), do: Spec.from_input(spec)

  defp spec_from_input(agent_module) when is_atom(agent_module) do
    cond do
      Code.ensure_loaded?(agent_module) and function_exported?(agent_module, :spec, 0) ->
        spec_from_input(agent_module.spec())

      Code.ensure_loaded?(agent_module) and function_exported?(agent_module, :__jidoka_agent__, 0) ->
        spec_from_input(Agent.spec(agent_module))

      true ->
        {:error, {:invalid_export_agent, agent_module}}
    end
  end

  defp spec_from_input(input), do: Spec.from_input(input)

  defp agent_document(%Spec{} = spec, opts) do
    with {:ok, context} <- context_document(spec, opts),
         {:ok, result} <- result_document(spec, opts) do
      agent =
        %{
          "id" => spec.id,
          "model" => Jidoka.Config.model_ref(spec.model),
          "generation" => portable_generation(spec.generation),
          "instructions" => spec.instructions,
          "context" => context,
          "result" => result,
          "memory" => portable_memory(spec.memory)
        }
        |> reject_empty_values()

      {:ok, agent}
    end
  end

  defp context_document(%Spec{context_schema: nil}, _opts), do: {:ok, nil}

  defp context_document(%Spec{}, opts) do
    case Keyword.get(opts, :context_schema_ref) do
      nil -> {:error, {:unexportable_context_schema, :missing_context_schema_ref}}
      ref -> {:ok, %{"ref" => to_string(ref)}}
    end
  end

  defp result_document(%Spec{result: nil}, _opts), do: {:ok, nil}

  defp result_document(%Spec{result: %Spec.Result{} = result}, opts) do
    case Keyword.get(opts, :result_schema_ref) || schema_ref(result.metadata) do
      nil ->
        {:error, {:unexportable_result_schema, :missing_result_schema_ref}}

      ref ->
        {:ok,
         %{
           "ref" => to_string(ref),
           "max_repairs" => result.max_repairs,
           "metadata" => portable_value(Map.delete(result.metadata, "schema_ref"))
         }
         |> reject_empty_values()}
    end
  end

  defp controls_document(%Controls{} = controls) do
    {:ok,
     %{
       "max_turns" => controls.max_turns,
       "timeout_ms" => controls.timeout_ms,
       "inputs" => Enum.map(controls.inputs, &boundary_control_document/1),
       "operations" => Enum.map(controls.operations, &operation_control_document/1),
       "outputs" => Enum.map(controls.outputs, &boundary_control_document/1)
     }
     |> reject_empty_values()}
  end

  defp boundary_control_document(%{control: control, metadata: metadata}) do
    %{
      "control" => control_ref(control),
      "metadata" => portable_value(metadata)
    }
    |> reject_empty_values()
  end

  defp operation_control_document(%Controls.Operation{} = operation) do
    %{
      "control" => control_ref(operation.control),
      "when" => portable_value(operation.match),
      "metadata" => portable_value(operation.metadata)
    }
    |> reject_empty_values()
  end

  defp operations_document(operations) when is_list(operations) do
    {:ok, Enum.map(operations, &operation_document/1)}
  end

  defp operation_document(%Spec.Operation{} = operation) do
    %{
      "name" => operation.name,
      "description" => operation.description,
      "idempotency" => Atom.to_string(operation.idempotency),
      "metadata" => portable_value(operation.metadata)
    }
    |> reject_empty_values()
  end

  defp portable_generation(nil), do: nil

  defp portable_generation(%Spec.Generation{} = generation) do
    %{
      "params" => portable_value(generation.params),
      "provider_options" => portable_value(generation.provider_options),
      "extra" => portable_value(generation.extra)
    }
    |> reject_empty_values()
  end

  defp portable_memory(nil), do: nil

  defp portable_memory(%Spec.Memory{} = memory) do
    %{
      "enabled" => memory.enabled,
      "scope" => Atom.to_string(memory.scope),
      "namespace" => portable_value(memory.namespace),
      "capture" => Atom.to_string(memory.capture),
      "inject" => Atom.to_string(memory.inject),
      "max_entries" => memory.max_entries,
      "metadata" => portable_value(memory.metadata)
    }
    |> reject_empty_values()
  end

  defp export_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.drop(["dsl_module", :dsl_module])
    |> portable_value()
  end

  defp export_metadata(metadata), do: portable_value(metadata)

  defp control_ref(module) when is_atom(module) do
    case Jidoka.Control.control_name(module) do
      {:ok, name} -> name
      {:error, _reason} -> inspect(module)
    end
  end

  defp schema_ref(metadata) when is_map(metadata),
    do: Map.get(metadata, "schema_ref") || Map.get(metadata, :schema_ref)

  defp schema_ref(_metadata), do: nil

  defp portable_value(%_{} = struct), do: inspect(struct)

  defp portable_value(%{} = map) do
    Map.new(map, fn {key, value} -> {portable_key(key), portable_value(value)} end)
  end

  defp portable_value(list) when is_list(list) do
    if Keyword.keyword?(list) do
      list
      |> Map.new()
      |> portable_value()
    else
      Enum.map(list, &portable_value/1)
    end
  end

  defp portable_value(tuple) when is_tuple(tuple), do: inspect(tuple)
  defp portable_value(atom) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)
  defp portable_value(value), do: value

  defp portable_key(key) when is_atom(key), do: Atom.to_string(key)
  defp portable_key(key), do: to_string(key)

  defp reject_empty_values(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, []} -> true
      {_key, value} when is_map(value) -> map_size(value) == 0
      {_key, _value} -> false
    end)
    |> Map.new()
  end

  defp normalize_format(format) when format in [:json, :yaml], do: {:ok, format}
  defp normalize_format("json"), do: {:ok, :json}
  defp normalize_format("yaml"), do: {:ok, :yaml}
  defp normalize_format(format), do: {:error, {:unsupported_export_format, format}}

  defp encode(document, :json, opts) do
    if Keyword.get(opts, :pretty, true) do
      Jason.encode(document, pretty: true)
    else
      Jason.encode(document)
    end
  end

  defp encode(document, :yaml, _opts), do: Ymlr.document(document, sort_maps: true)
end
