defmodule Jidoka.CodingPack.Mutation do
  @moduledoc false

  alias Jidoka.Cancellation
  alias Jidoka.CodingPack.{Error, Ignore, MutationPort, Workspace}
  alias Jidoka.ExecutionEnvironment.{Checkpoint, EnforcementEvidence}

  @type guard_fun :: (map() -> :ok | {:error, Error.t()})
  @type content_source :: String.t() | (map() -> String.t())

  @doc false
  @spec run(
          Workspace.t(),
          MutationPort.t(),
          String.t(),
          content_source(),
          String.t(),
          String.t(),
          guard_fun(),
          keyword()
        ) ::
          {:ok, map()} | {:error, Error.t()}
  def run(workspace, port, path, content_source, action, operation_id, guard, opts \\ [])

  def run(
        %Workspace{} = workspace,
        %MutationPort{} = port,
        path,
        content_source,
        action,
        operation_id,
        guard,
        opts
      )
      when is_binary(path) and (is_binary(content_source) or is_function(content_source, 1)) and
             is_binary(action) and is_binary(operation_id) and
             is_function(guard, 1) and is_list(opts) do
    with :ok <- write_access(workspace),
         {:ok, target} <- target(workspace, path),
         :ok <- included(workspace, target.relative),
         {:ok, before, _read_evidence} <- MutationPort.inspect_file(port, workspace, target.relative),
         :ok <- bounded_before(before, workspace.limits.max_file_bytes),
         :ok <- guard.(before),
         {:ok, content} <- desired_content(content_source, before),
         :ok <- valid_text(content),
         :ok <- bounded(content, workspace.limits.max_file_bytes),
         {:ok, checkpoint, checkpoint_evidence} <- MutationPort.checkpoint(port, workspace) do
      transact(%{
        workspace: workspace,
        port: port,
        target: target,
        content: content,
        action: action,
        operation_id: operation_id,
        before: before,
        checkpoint: checkpoint,
        checkpoint_evidence: checkpoint_evidence,
        opts: opts
      })
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp transact(transaction) do
    with :ok <- cancellation(transaction.opts),
         {:ok, current_target} <- target(transaction.workspace, transaction.target.relative),
         true <- current_target.relative == transaction.target.relative,
         :ok <- included(transaction.workspace, current_target.relative),
         {:ok, current, _read_evidence} <-
           MutationPort.inspect_file(transaction.port, transaction.workspace, current_target.relative),
         :ok <- unchanged(transaction.before, current),
         :ok <- cancellation(transaction.opts),
         {:ok, replacement, evidence} <-
           MutationPort.replace_file(
             transaction.port,
             transaction.workspace,
             current_target.relative,
             transaction.content
           ),
         :ok <- final_state(replacement["final_state"], transaction.content) do
      transaction = Map.put(transaction, :path, current_target.relative)
      {:ok, edit_record(transaction, replacement, evidence)}
    else
      false ->
        recoverable_error(
          transaction.port,
          transaction.workspace,
          transaction.target.relative,
          transaction.checkpoint,
          :coding_path_changed
        )

      {:error, %Error{} = error} ->
        recoverable_error(
          transaction.port,
          transaction.workspace,
          transaction.target.relative,
          transaction.checkpoint,
          error
        )
    end
  end

  defp edit_record(transaction, replacement, evidence) do
    after_state = replacement["final_state"]

    %{
      "path" => transaction.path,
      "action" => transaction.action,
      "operation_id" => transaction.operation_id,
      "before_sha256" => transaction.before.sha256,
      "after_sha256" => after_state["sha256"],
      "before_size" => transaction.before.size,
      "after_size" => after_state["size"],
      "summary" => summary(transaction.action, transaction.path),
      "write_method" => replacement["method"],
      "checkpoint" => Checkpoint.to_map(transaction.checkpoint),
      "checkpoint_enforcement" => EnforcementEvidence.to_map(transaction.checkpoint_evidence),
      "enforcement" => EnforcementEvidence.to_map(evidence),
      "diff" => diff(transaction.before.content || "", transaction.content)
    }
  end

  defp diff(before, after_content) do
    before_lines = String.split(before, "\n", trim: false)
    after_lines = String.split(after_content, "\n", trim: false)
    prefix = common_prefix(before_lines, after_lines)

    suffix =
      common_prefix(
        Enum.reverse(Enum.drop(before_lines, prefix)),
        Enum.reverse(Enum.drop(after_lines, prefix))
      )

    %{
      "before_lines" => length(before_lines),
      "after_lines" => length(after_lines),
      "common_prefix_lines" => prefix,
      "common_suffix_lines" => suffix,
      "changed_before_lines" => max(length(before_lines) - prefix - suffix, 0),
      "changed_after_lines" => max(length(after_lines) - prefix - suffix, 0),
      "contains_content" => false
    }
  end

  defp common_prefix(left, right) do
    left
    |> Enum.zip(right)
    |> Enum.take_while(fn {left_line, right_line} -> left_line == right_line end)
    |> length()
  end

  defp recoverable_error(port, workspace, path, checkpoint, reason) do
    final_state =
      case MutationPort.inspect_file(port, workspace, path) do
        {:ok, state, _evidence} -> project_state(state)
        {:error, _error} -> "unknown"
      end

    {code, cause} =
      case reason do
        %Error{code: code, details: details} -> {code, details}
        code when is_atom(code) -> {code, %{}}
      end

    {:error,
     Error.new(code, %{
       cause: cause,
       final_state: final_state,
       checkpoint: Checkpoint.to_map(checkpoint),
       recovery: "restore_available"
     })}
  end

  defp target(workspace, path), do: Workspace.resolve(workspace, path, allow_missing: true)

  defp included(workspace, path) do
    case Ignore.decision(workspace, path) do
      {:ok, %{ignored?: false}} -> :ok
      {:ok, decision} -> {:error, Error.new(:coding_path_ignored, %{path: path, decision: decision})}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp write_access(workspace) do
    if Workspace.permits?(workspace, :write),
      do: :ok,
      else: {:error, Error.new(:coding_write_denied, %{reason: :workspace_access})}
  end

  defp valid_text(content) do
    if String.valid?(content) and not String.contains?(content, <<0>>),
      do: :ok,
      else: {:error, Error.new(:coding_write_content_invalid)}
  end

  defp desired_content(content, _before) when is_binary(content), do: {:ok, content}

  defp desired_content(builder, before) when is_function(builder, 1) do
    case builder.(before) do
      content when is_binary(content) -> {:ok, content}
      _value -> {:error, Error.new(:coding_write_content_invalid)}
    end
  rescue
    exception -> {:error, Error.new(:coding_write_content_invalid, %{reason: inspect(exception)})}
  end

  defp bounded(content, limit) when byte_size(content) <= limit, do: :ok

  defp bounded(content, limit),
    do: {:error, Error.new(:coding_file_too_large, %{size: byte_size(content), limit: limit})}

  defp bounded_before(%{exists?: false}, _limit), do: :ok
  defp bounded_before(%{content: content}, limit), do: bounded(content, limit)

  defp unchanged(before, current) do
    if before.exists? == current.exists? and before.sha256 == current.sha256,
      do: :ok,
      else: {:error, Error.new(:coding_write_conflict, %{reason: :file_changed_before_write})}
  end

  defp final_state(%{"exists" => true, "sha256" => digest, "size" => size}, content) do
    if digest == digest(content) and size == byte_size(content),
      do: :ok,
      else: {:error, Error.new(:coding_mutation_final_state_invalid)}
  end

  defp final_state(_state, _content), do: {:error, Error.new(:coding_mutation_final_state_invalid)}

  defp cancellation(opts) do
    case Cancellation.check(opts) do
      :ok -> :ok
      {:error, :cancelled} -> {:error, Error.new(:coding_mutation_cancelled)}
    end
  end

  defp project_state(state),
    do: %{"exists" => state.exists?, "sha256" => state.sha256, "size" => state.size}

  defp summary("create", path), do: "Created #{path}."
  defp summary("replace", path), do: "Replaced #{path}."
  defp summary("edit", path), do: "Edited #{path}."

  defp digest(value), do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
end
