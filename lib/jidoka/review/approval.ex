defmodule Jidoka.Review.Approval do
  @moduledoc false

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Review.Policy

  @type source_policy :: true | false | nil | :unsafe_once | keyword() | map() | Policy.t()

  @spec apply_to_operation!(Operation.t(), source_policy()) :: Operation.t()
  def apply_to_operation!(%Operation{} = operation, approval) do
    case policy_for_operation(approval, operation) do
      {:ok, nil} -> operation
      {:ok, %Policy{} = policy} -> %Operation{operation | approval: policy}
      {:error, reason} -> raise ArgumentError, "invalid approval policy: #{inspect(reason)}"
    end
  end

  @spec apply_to_operations!([Operation.t()], source_policy()) :: [Operation.t()]
  def apply_to_operations!(operations, approval) when is_list(operations) do
    Enum.map(operations, &apply_to_operation!(&1, approval))
  end

  @spec policy_for_operation(source_policy(), Operation.t() | map()) ::
          {:ok, Policy.t() | nil} | {:error, term()}
  def policy_for_operation(nil, _operation), do: {:ok, nil}
  def policy_for_operation(false, _operation), do: {:ok, nil}
  def policy_for_operation(true, _operation), do: Policy.from_input(true)

  def policy_for_operation(:unsafe_once, operation) do
    if operation_idempotency(operation) == :unsafe_once do
      Policy.from_input(true)
    else
      {:ok, nil}
    end
  end

  def policy_for_operation(%Policy{} = policy, _operation), do: Policy.from_input(policy)

  def policy_for_operation(input, operation) when is_list(input) do
    input
    |> Map.new()
    |> policy_for_operation(operation)
  rescue
    exception -> {:error, {:invalid_approval_policy, exception}}
  end

  def policy_for_operation(%{} = input, operation) do
    with {:ok, input} <- normalize_source_policy(input),
         true <- source_policy_matches?(input, operation) do
      input
      |> Map.drop([:only, :except])
      |> Policy.from_input()
    else
      false -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  def policy_for_operation(other, _operation), do: {:error, {:invalid_approval_policy, other}}

  @spec source_policy_map(source_policy()) :: map() | nil
  def source_policy_map(nil), do: nil
  def source_policy_map(false), do: nil
  def source_policy_map(true), do: Policy.to_map(Policy.new!(%{}))
  def source_policy_map(:unsafe_once), do: %{"required" => true, "mode" => "pre_execution", "only" => "unsafe_once"}
  def source_policy_map(%Policy{} = policy), do: Policy.to_map(policy)

  def source_policy_map(input) when is_list(input) do
    input
    |> Map.new()
    |> source_policy_map()
  end

  def source_policy_map(%{} = input) do
    input
    |> normalize_source_policy!()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), portable_value(value)} end)
  end

  def source_policy_map(_other), do: nil

  defp normalize_source_policy(input) when is_map(input) do
    input = normalize_keys(input)

    with {:ok, only} <- normalize_names(Map.get(input, :only), :only),
         {:ok, except} <- normalize_names(Map.get(input, :except), :except) do
      {:ok,
       input
       |> Map.put(:only, only)
       |> Map.put(:except, except)}
    end
  end

  defp normalize_source_policy!(input) do
    case normalize_source_policy(input) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  defp source_policy_matches?(%{} = source, operation) do
    name = operation_name(operation)
    idempotency = operation_idempotency(operation)
    only = Map.get(source, :only, [])
    except = Map.get(source, :except, [])

    only_match? =
      only == [] or name in only or (idempotency == :unsafe_once and "unsafe_once" in only)

    except_match? =
      name in except or (idempotency == :unsafe_once and "unsafe_once" in except)

    only_match? and not except_match?
  end

  defp normalize_keys(map) do
    Map.new(map, fn
      {key, value} when key in [:only, "only"] -> {:only, value}
      {key, value} when key in [:except, "except"] -> {:except, value}
      {key, value} when key in [:required, "required"] -> {:required, value}
      {key, value} when key in [:mode, "mode"] -> {:mode, value}
      {key, value} when key in [:reason, "reason"] -> {:reason, value}
      {key, value} when key in [:message, "message"] -> {:message, value}
      {key, value} when key in [:when, "when", :predicate, "predicate"] -> {:predicate, value}
      {key, value} when key in [:ttl_ms, "ttl_ms"] -> {:ttl_ms, value}
      {key, value} when key in [:metadata, "metadata"] -> {:metadata, value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_names(nil, _field), do: {:ok, []}

  defp normalize_names(values, field) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case normalize_name(value, field) do
        {:ok, name} -> {:cont, {:ok, [name | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, Enum.reverse(names)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_names(value, field), do: normalize_names([value], field)

  defp normalize_name(:unsafe_once, _field), do: {:ok, "unsafe_once"}

  defp normalize_name(value, _field) when is_atom(value) and not is_nil(value) do
    {:ok, Atom.to_string(value)}
  end

  defp normalize_name(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_approval_filter, field, value}}
      value -> {:ok, value}
    end
  end

  defp normalize_name(value, field), do: {:error, {:invalid_approval_filter, field, value}}

  defp operation_name(%Operation{name: name}), do: name

  defp operation_name(%{} = operation) do
    operation
    |> get_any([:name, "name", :operation, "operation"])
    |> normalize_operation_name()
  end

  defp operation_idempotency(%Operation{idempotency: idempotency}), do: idempotency

  defp operation_idempotency(%{} = operation) do
    operation
    |> get_any([:idempotency, "idempotency"])
    |> normalize_idempotency()
  end

  defp normalize_operation_name(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp normalize_operation_name(value) when is_binary(value), do: value
  defp normalize_operation_name(_value), do: nil

  defp normalize_idempotency(value) when is_atom(value), do: value

  defp normalize_idempotency(value) when is_binary(value) do
    case String.trim(value) do
      "unsafe_once" -> :unsafe_once
      other -> other
    end
  end

  defp normalize_idempotency(value), do: value

  defp get_any(map, keys), do: Enum.find_value(keys, &Map.get(map, &1))

  defp portable_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp portable_value(values) when is_list(values), do: Enum.map(values, &portable_value/1)
  defp portable_value(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), portable_value(value)} end)
  defp portable_value(value), do: value
end
