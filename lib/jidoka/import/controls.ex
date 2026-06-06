defmodule Jidoka.Import.Controls do
  @moduledoc false

  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Import.Normalize
  alias Jidoka.Import.Registry
  alias Jidoka.Schema

  @spec from_import(map(), keyword()) :: {:ok, Controls.t()} | {:error, term()}
  def from_import(controls, opts) when is_map(controls) do
    with :ok <- reject_legacy_result_controls(controls),
         {:ok, inputs} <-
           boundary_controls(
             controls,
             opts,
             [:inputs, :input],
             Controls.Input,
             :invalid_input_control
           ),
         {:ok, operations} <- operation_controls(controls, opts),
         {:ok, outputs} <-
           boundary_controls(
             controls,
             opts,
             [:outputs, :output],
             Controls.Output,
             :invalid_output_control
           ) do
      Controls.new(
        max_turns: Schema.get_key(controls, :max_turns),
        timeout_ms: Schema.get_key(controls, :timeout_ms) || Schema.get_key(controls, :timeout),
        inputs: inputs,
        operations: operations,
        outputs: outputs
      )
    end
  end

  defp reject_legacy_result_controls(controls) do
    cond do
      match?({:ok, _value}, Schema.fetch_key(controls, :result)) ->
        {:error, {:unsupported_control_key, :result, :output}}

      match?({:ok, _value}, Schema.fetch_key(controls, :results)) ->
        {:error, {:unsupported_control_key, :results, :outputs}}

      true ->
        :ok
    end
  end

  defp boundary_controls(controls, opts, keys, module, reason) do
    controls
    |> Normalize.first_value(keys)
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, boundary_controls} ->
      case boundary_control(attrs, opts, module, reason) do
        {:ok, boundary_control} -> {:cont, {:ok, [boundary_control | boundary_controls]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, boundary_controls} -> {:ok, Enum.reverse(boundary_controls)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp operation_controls(controls, opts) do
    controls
    |> Normalize.first_value([:operations, :operation])
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, operations} ->
      case control_operation(attrs, opts) do
        {:ok, operation} -> {:cont, {:ok, [operation | operations]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp boundary_control(%{} = attrs, opts, module, _reason) do
    attrs = Normalize.stringify_keys(attrs)

    with {:ok, control} <-
           resolve_control(Schema.get_key(attrs, :control) || Schema.get_key(attrs, :ref), opts) do
      module.new(
        control: control,
        metadata: Schema.get_key(attrs, :metadata, %{})
      )
    end
  end

  defp boundary_control(other, _opts, _module, reason), do: {:error, {reason, other}}

  defp control_operation(%{} = attrs, opts) do
    attrs = Normalize.stringify_keys(attrs)

    with {:ok, control} <-
           resolve_control(Schema.get_key(attrs, :control) || Schema.get_key(attrs, :ref), opts) do
      Controls.Operation.new(
        control: control,
        match: Schema.get_key(attrs, :when) || Schema.get_key(attrs, :match) || %{},
        metadata: Schema.get_key(attrs, :metadata, %{})
      )
    end
  end

  defp control_operation(other, _opts), do: {:error, {:invalid_operation_control, other}}

  defp resolve_control(nil, _opts), do: {:error, :missing_control_ref}

  defp resolve_control(control, _opts) when is_atom(control) and not is_nil(control) do
    case Jidoka.Control.validate_module(control) do
      :ok -> {:ok, control}
      {:error, message} -> {:error, {:invalid_control_module, control, message}}
    end
  end

  defp resolve_control(ref, opts) when is_binary(ref), do: Registry.fetch(:controls, ref, opts)
  defp resolve_control(other, _opts), do: {:error, {:invalid_control_ref, other}}
end
