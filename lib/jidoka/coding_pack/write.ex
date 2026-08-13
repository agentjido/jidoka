defmodule Jidoka.CodingPack.Write do
  @moduledoc "Reviewed bounded file creation and replacement through a constrained environment."

  alias Jidoka.CodingPack.{Error, Mutation, MutationPort, Workspace}
  alias Jidoka.Effect.OperationRequest

  @keys ~w(path content overwrite expected_before_sha256)

  @doc "Returns the model-visible write operation and its constrained handler."
  @spec tool(Workspace.t(), MutationPort.t()) ::
          %{operation: Jidoka.Agent.Spec.Operation.t(), handler: function()}
  def tool(%Workspace{} = workspace, %MutationPort{} = port) do
    %{
      operation:
        Jidoka.Agent.Spec.Operation.new!(
          name: "coding.write",
          description: "Create or replace one bounded workspace text file after policy review.",
          idempotency: :reconcile,
          metadata: %{
            "kind" => "tool",
            "source" => "coding_pack",
            "parameters_schema" => input_schema(),
            "policy_resource" => %{
              "kind" => "coding_workspace",
              "access" => "write",
              "argument_fields" => ["path", "overwrite", "expected_before_sha256"]
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

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "minLength" => 1},
        "content" => %{"type" => "string"},
        "overwrite" => %{"type" => "boolean"},
        "expected_before_sha256" => %{"type" => "string", "pattern" => "^sha256:[0-9a-f]{64}$"}
      },
      "required" => ["path", "content"],
      "additionalProperties" => false
    }
  end

  @doc "Creates or replaces one text file with optimistic concurrency checks."
  @spec run(Workspace.t(), MutationPort.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(workspace, port, arguments, opts \\ [])

  def run(%Workspace{} = workspace, %MutationPort{} = port, arguments, opts)
      when is_map(arguments) and is_list(opts) do
    with {:ok, input} <- input(arguments) do
      guard = fn before -> write_guard(before, input) end
      action = if input.overwrite, do: "replace", else: "create"

      Mutation.run(
        workspace,
        port,
        input.path,
        input.content,
        action,
        Keyword.get(opts, :operation_id, "coding.write"),
        guard,
        opts
      )
    end
  end

  def run(%Workspace{}, %MutationPort{}, _arguments, _opts),
    do: {:error, Error.new(:coding_write_input_invalid)}

  defp input(arguments) do
    arguments = stringify_keys(arguments)
    unknown = Map.keys(arguments) -- @keys
    path = Map.get(arguments, "path")
    content = Map.get(arguments, "content")
    overwrite = Map.get(arguments, "overwrite", false)
    expected = Map.get(arguments, "expected_before_sha256")

    if unknown == [] and is_binary(path) and path != "" and is_binary(content) and
         is_boolean(overwrite) and valid_digest?(expected) do
      {:ok, %{path: path, content: content, overwrite: overwrite, expected: expected}}
    else
      {:error, Error.new(:coding_write_input_invalid, %{unknown_keys: unknown})}
    end
  end

  defp write_guard(%{exists?: false}, %{overwrite: false, expected: nil}), do: :ok

  defp write_guard(%{exists?: false}, %{expected: expected}) when is_binary(expected),
    do: {:error, Error.new(:coding_write_conflict, %{reason: :expected_existing_file})}

  defp write_guard(%{exists?: false}, %{overwrite: true}),
    do: {:error, Error.new(:coding_write_conflict, %{reason: :overwrite_target_missing})}

  defp write_guard(%{exists?: true}, %{overwrite: false}),
    do: {:error, Error.new(:coding_write_overwrite_required)}

  defp write_guard(%{exists?: true, sha256: digest}, %{overwrite: true, expected: expected}) do
    if is_nil(expected) or expected == digest,
      do: :ok,
      else: {:error, Error.new(:coding_write_conflict, %{expected: expected, actual: digest})}
  end

  defp valid_digest?(nil), do: true
  defp valid_digest?("sha256:" <> digest), do: byte_size(digest) == 64 and digest =~ ~r/\A[0-9a-f]+\z/
  defp valid_digest?(_value), do: false

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
