defmodule Jidoka.CodingPack.Edit do
  @moduledoc "Exact bounded text edits through a constrained environment."

  alias Jidoka.CodingPack.{Error, Mutation, MutationPort, Workspace}
  alias Jidoka.Effect.OperationRequest

  @keys ~w(path old_text new_text expected_occurrences expected_before_sha256)

  @doc "Returns the model-visible exact-edit operation and its constrained handler."
  @spec tool(Workspace.t(), MutationPort.t()) ::
          %{operation: Jidoka.Agent.Spec.Operation.t(), handler: function()}
  def tool(%Workspace{} = workspace, %MutationPort{} = port) do
    %{
      operation:
        Jidoka.Agent.Spec.Operation.new!(
          name: "coding.edit",
          description: "Replace an exact text value after count, digest, and policy checks.",
          idempotency: :reconcile,
          metadata: %{
            "kind" => "tool",
            "source" => "coding_pack",
            "policy_resource" => %{
              "kind" => "coding_workspace",
              "access" => "write",
              "argument_fields" => ["path", "expected_occurrences", "expected_before_sha256"]
            }
          }
        ),
      handler: fn intent, _journal, context ->
        with {:ok, request} <- OperationRequest.from_input(intent.payload) do
          run(workspace, port, request.arguments,
            operation_id: intent.id,
            cancellation: Jidoka.Context.get_runtime(context, :cancellation)
          )
        end
      end
    }
  end

  @doc "Replaces an exact text value only when all guards match."
  @spec run(Workspace.t(), MutationPort.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(workspace, port, arguments, opts \\ [])

  def run(%Workspace{} = workspace, %MutationPort{} = port, arguments, opts)
      when is_map(arguments) and is_list(opts) do
    with {:ok, input} <- input(arguments) do
      guard = fn before -> edit_guard(before, input) end
      content = fn before -> String.replace(before.content, input.old_text, input.new_text) end

      Mutation.run(
        workspace,
        port,
        input.path,
        content,
        "edit",
        Keyword.get(opts, :operation_id, "coding.edit"),
        guard,
        opts
      )
    end
  end

  def run(%Workspace{}, %MutationPort{}, _arguments, _opts),
    do: {:error, Error.new(:coding_edit_input_invalid)}

  defp input(arguments) do
    arguments = stringify_keys(arguments)
    unknown = Map.keys(arguments) -- @keys
    path = Map.get(arguments, "path")
    old_text = Map.get(arguments, "old_text")
    new_text = Map.get(arguments, "new_text")
    expected_occurrences = Map.get(arguments, "expected_occurrences", 1)
    expected_digest = Map.get(arguments, "expected_before_sha256")

    if unknown == [] and valid_path?(path) and valid_old_text?(old_text) and is_binary(new_text) and
         valid_occurrences?(expected_occurrences) and valid_digest?(expected_digest) do
      {:ok,
       %{
         path: path,
         old_text: old_text,
         new_text: new_text,
         expected_occurrences: expected_occurrences,
         expected_digest: expected_digest
       }}
    else
      {:error, Error.new(:coding_edit_input_invalid, %{unknown_keys: unknown})}
    end
  end

  defp edit_guard(%{exists?: false}, _input),
    do: {:error, Error.new(:coding_file_not_found)}

  defp edit_guard(%{exists?: true} = before, input) do
    occurrences = length(:binary.matches(before.content, input.old_text))

    cond do
      is_binary(input.expected_digest) and input.expected_digest != before.sha256 ->
        {:error,
         Error.new(:coding_write_conflict, %{
           expected: input.expected_digest,
           actual: before.sha256
         })}

      occurrences != input.expected_occurrences ->
        {:error,
         Error.new(:coding_edit_occurrence_mismatch, %{
           expected: input.expected_occurrences,
           actual: occurrences
         })}

      true ->
        :ok
    end
  end

  defp valid_digest?(nil), do: true
  defp valid_digest?("sha256:" <> digest), do: byte_size(digest) == 64 and digest =~ ~r/\A[0-9a-f]+\z/
  defp valid_digest?(_value), do: false
  defp valid_path?(path), do: is_binary(path) and path != ""
  defp valid_old_text?(text), do: is_binary(text) and text != ""
  defp valid_occurrences?(count), do: is_integer(count) and count > 0

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
