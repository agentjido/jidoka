defmodule Jidoka.Eval.Assertion do
  @moduledoc "Closed input assertion for a deterministic evaluation case."

  alias Jidoka.Schema

  @kinds [:contains, :equals, :operation_called]

  @schema Zoi.discriminated_union(
            :kind,
            [
              Zoi.object(%{kind: Zoi.literal(:contains), expected: Schema.non_empty_string()}),
              Zoi.object(%{kind: Zoi.literal(:equals), expected: Zoi.any()}),
              Zoi.object(%{kind: Zoi.literal(:operation_called), expected: Schema.non_empty_string()})
            ],
            coerce: true
          )

  @type kind :: :contains | :equals | :operation_called
  @type t :: %{required(:kind) => kind(), required(:expected) => term()}

  @doc "Returns the closed assertion variant schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Normalizes one tagged assertion variant."
  @spec from_input(map()) :: {:ok, t()} | {:error, term()}
  def from_input(%{} = input) do
    with :ok <- validate_keys(input),
         {:ok, kind} <- fetch_kind(input),
         {:ok, expected} <- fetch_expected(input),
         {:ok, expected} <- normalize_expected(kind, expected) do
      Schema.parse(@schema, %{kind: kind, expected: expected})
    end
  end

  def from_input(input), do: {:error, {:invalid_eval_assertion, input}}

  @doc "Normalizes a closed assertion list or a supported legacy assertion map."
  @spec normalize(term()) :: {:ok, [t()]} | {:error, term()}
  def normalize(assertions) when is_list(assertions) do
    assertions
    |> Enum.reduce_while({:ok, []}, fn assertion, {:ok, normalized} ->
      case from_input(assertion) do
        {:ok, assertion} -> {:cont, {:ok, normalized ++ [assertion]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> require_non_empty()
  end

  def normalize(%{} = assertions) do
    with :ok <- validate_legacy_keys(assertions) do
      @kinds
      |> Enum.flat_map(&legacy_variants(&1, Schema.get_key(assertions, &1)))
      |> normalize()
    end
  end

  def normalize(assertions), do: {:error, {:invalid_eval_assertions, assertions}}

  defp validate_keys(input) do
    unknown = Enum.reject(Map.keys(input), &(&1 in [:kind, "kind", :expected, "expected"]))

    case unknown do
      [] -> :ok
      keys -> {:error, {:invalid_eval_assertion, {:unknown_keys, Enum.sort(keys)}}}
    end
  end

  defp validate_legacy_keys(input) do
    allowed = @kinds ++ Enum.map(@kinds, &Atom.to_string/1)
    unknown = Enum.reject(Map.keys(input), &(&1 in allowed))

    case unknown do
      [] -> :ok
      keys -> {:error, {:invalid_eval_assertions, {:unknown_keys, Enum.sort(keys)}}}
    end
  end

  defp fetch_kind(input) do
    case Schema.fetch_key(input, :kind) do
      {:ok, kind} when kind in @kinds -> {:ok, kind}
      {:ok, kind} when is_binary(kind) -> normalize_binary_kind(kind)
      {:ok, kind} -> {:error, {:invalid_eval_assertion, {:unknown_kind, kind}}}
      :error -> {:error, {:invalid_eval_assertion, :missing_kind}}
    end
  end

  defp normalize_binary_kind(kind) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == kind)) do
      nil -> {:error, {:invalid_eval_assertion, {:unknown_kind, kind}}}
      kind -> {:ok, kind}
    end
  end

  defp fetch_expected(input) do
    case Schema.fetch_key(input, :expected) do
      {:ok, expected} -> {:ok, expected}
      :error -> {:error, {:invalid_eval_assertion, :missing_expected}}
    end
  end

  defp normalize_expected(kind, expected) when kind in [:contains, :operation_called] and is_atom(expected),
    do: normalize_expected(kind, Atom.to_string(expected))

  defp normalize_expected(kind, expected)
       when kind in [:contains, :operation_called] and is_binary(expected) and expected != "",
       do: {:ok, expected}

  defp normalize_expected(:equals, expected), do: {:ok, expected}
  defp normalize_expected(kind, expected), do: {:error, {:invalid_eval_assertion, {kind, expected}}}

  defp legacy_variants(_kind, nil), do: []
  defp legacy_variants(:equals, expected), do: [%{kind: :equals, expected: expected}]

  defp legacy_variants(kind, expected) do
    expected
    |> List.wrap()
    |> Enum.map(&%{kind: kind, expected: &1})
  end

  defp require_non_empty({:ok, []}), do: {:error, {:invalid_eval_assertions, :empty}}
  defp require_non_empty(result), do: result
end
