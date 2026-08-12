defmodule Jidoka.CodingPack.MutationPort do
  @moduledoc "Validated host-owned port to constrained workspace mutation capabilities."

  alias Jidoka.CodingPack.{Error, Workspace}
  alias Jidoka.ExecutionEnvironment.{Checkpoint, EnforcementEvidence}

  @enforce_keys [:backend, :opts]
  defstruct [:backend, opts: []]

  @type t :: %__MODULE__{backend: module(), opts: keyword()}
  @callbacks [checkpoint: 2, inspect_file: 3, replace_file: 4, restore: 3]

  @doc "Builds a mutation port from a trusted backend module and private options."
  @spec new(module(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(backend, opts \\ []) when is_atom(backend) and is_list(opts) do
    if Code.ensure_loaded?(backend) and
         Enum.all?(@callbacks, fn {name, arity} -> function_exported?(backend, name, arity) end),
       do: {:ok, %__MODULE__{backend: backend, opts: opts}},
       else: {:error, Error.new(:coding_mutation_backend_invalid, %{backend: inspect(backend)})}
  end

  @doc "Creates a portable environment checkpoint before a mutation."
  @spec checkpoint(t(), Workspace.t()) ::
          {:ok, Checkpoint.t(), EnforcementEvidence.t()} | {:error, Error.t()}
  def checkpoint(%__MODULE__{} = port, %Workspace{} = workspace) do
    with {:ok, checkpoint, evidence} <- call(port, :checkpoint, [workspace, port.opts]),
         {:ok, checkpoint} <- Checkpoint.new(checkpoint),
         {:ok, evidence} <- evidence(evidence, :checkpoint) do
      {:ok, checkpoint, evidence}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:coding_checkpoint_failed, %{reason: inspect(reason)})}
    end
  end

  @doc "Inspects one file through the constrained environment."
  @spec inspect_file(t(), Workspace.t(), String.t()) :: {:ok, map(), EnforcementEvidence.t()} | {:error, Error.t()}
  def inspect_file(%__MODULE__{} = port, %Workspace{} = workspace, path) do
    with {:ok, state, evidence} <- call(port, :inspect_file, [workspace, path, port.opts]),
         {:ok, evidence} <- evidence(evidence, :read),
         {:ok, state} <- file_state(state) do
      {:ok, state, evidence}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:coding_mutation_inspect_failed, %{path: path, reason: inspect(reason)})}
    end
  end

  @doc "Atomically replaces one file and validates confirmed final state."
  @spec replace_file(t(), Workspace.t(), String.t(), String.t()) ::
          {:ok, map(), EnforcementEvidence.t()} | {:error, Error.t()}
  def replace_file(%__MODULE__{} = port, %Workspace{} = workspace, path, content) do
    case call(port, :replace_file, [workspace, path, content, port.opts]) do
      {:ok, result, evidence} ->
        normalize_replace(result, evidence, path)

      {:error, reason, final_state, evidence} ->
        normalize_partial_error(reason, final_state, evidence, path)

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:coding_mutation_failed, %{path: path, reason: inspect(reason), changed: "unknown"})}
    end
  end

  @doc "Restores one checkpoint through the constrained environment."
  @spec restore(t(), Workspace.t(), Checkpoint.t()) :: {:ok, EnforcementEvidence.t()} | {:error, Error.t()}
  def restore(%__MODULE__{} = port, %Workspace{} = workspace, %Checkpoint{} = checkpoint) do
    with {:ok, evidence} <- call(port, :restore, [workspace, checkpoint, port.opts]),
         {:ok, evidence} <- evidence(evidence, :write) do
      {:ok, evidence}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:coding_restore_failed, %{reason: inspect(reason)})}
    end
  end

  defp normalize_replace(result, raw_evidence, path) when is_map(result) do
    with {:ok, evidence} <- evidence(raw_evidence, :write),
         true <- value(result, :method) in [:atomic_replace, "atomic_replace"],
         {:ok, final_state} <- file_state(value(result, :final_state)) do
      {:ok, %{"method" => "atomic_replace", "final_state" => project_state(final_state)}, evidence}
    else
      false -> {:error, Error.new(:coding_mutation_method_unconfirmed, %{path: path})}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:coding_mutation_result_invalid, %{path: path, reason: inspect(reason)})}
    end
  end

  defp normalize_replace(_result, _evidence, path),
    do: {:error, Error.new(:coding_mutation_result_invalid, %{path: path})}

  defp normalize_partial_error(reason, final_state, raw_evidence, path) do
    with {:ok, evidence} <- evidence(raw_evidence, :write),
         {:ok, final_state} <- file_state(final_state) do
      {:error,
       Error.new(:coding_mutation_failed, %{
         path: path,
         reason: inspect(reason),
         final_state: project_state(final_state),
         enforcement: EnforcementEvidence.to_map(evidence)
       })}
    else
      {:error, validation} ->
        {:error,
         Error.new(:coding_mutation_failed, %{
           path: path,
           reason: inspect(reason),
           final_state: "unknown",
           evidence_error: inspect(validation)
         })}
    end
  end

  defp file_state(state) when is_map(state) do
    exists? = value(state, :exists?)

    if is_boolean(exists?),
      do: normalize_file_state(exists?, value(state, :content), state),
      else: {:error, :invalid_exists}
  end

  defp file_state(_state), do: {:error, :invalid_file_state}

  defp normalize_file_state(false, nil, _state),
    do: {:ok, %{exists?: false, content: nil, sha256: nil, size: 0}}

  defp normalize_file_state(true, content, state)
       when is_binary(content) do
    if String.valid?(content) and not String.contains?(content, <<0>>),
      do: verified_file_state(content, state),
      else: {:error, :invalid_file_state}
  end

  defp normalize_file_state(_exists, _content, _state), do: {:error, :invalid_file_state}

  defp verified_file_state(content, state) do
    content_digest = digest(content)
    supplied_digest = value(state, :sha256)
    supplied_size = value(state, :size)

    if supplied_digest in [nil, content_digest] and supplied_size in [nil, byte_size(content)],
      do: {:ok, %{exists?: true, content: content, sha256: content_digest, size: byte_size(content)}},
      else: {:error, :file_state_mismatch}
  end

  defp evidence(raw, operation) do
    with {:ok, evidence} <- EnforcementEvidence.new(raw),
         true <- evidence.status == :confirmed,
         true <- evidence.isolation in [:process, :container, :vm, :microvm],
         true <- evidence.workspace in [:ephemeral, :persistent, :isolated_copy],
         true <- fact(evidence, "path_confined"),
         true <- evidence_fact(operation, evidence) do
      {:ok, evidence}
    else
      reason ->
        {:error, Error.new(:coding_mutation_enforcement_unconfirmed, %{operation: operation, reason: inspect(reason)})}
    end
  end

  defp evidence_fact(:checkpoint, evidence), do: fact(evidence, "checkpoint")
  defp evidence_fact(:read, evidence), do: fact(evidence, "filesystem_read")
  defp evidence_fact(:write, evidence), do: fact(evidence, "filesystem_write") and fact(evidence, "atomic_replace")

  defp fact(evidence, "path_confined"),
    do: Map.get(evidence.facts, "path_confined") == true or Map.get(evidence.facts, :path_confined) == true

  defp fact(evidence, "checkpoint"),
    do: Map.get(evidence.facts, "checkpoint") == true or Map.get(evidence.facts, :checkpoint) == true

  defp fact(evidence, "filesystem_read"),
    do: Map.get(evidence.facts, "filesystem_read") == true or Map.get(evidence.facts, :filesystem_read) == true

  defp fact(evidence, "filesystem_write"),
    do: Map.get(evidence.facts, "filesystem_write") == true or Map.get(evidence.facts, :filesystem_write) == true

  defp fact(evidence, "atomic_replace"),
    do: Map.get(evidence.facts, "atomic_replace") == true or Map.get(evidence.facts, :atomic_replace) == true

  defp call(port, function, arguments) do
    apply(port.backend, function, arguments)
  rescue
    exception -> {:error, {:backend_exception, exception}}
  catch
    kind, reason -> {:error, {:backend_failure, {kind, reason}}}
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp project_state(state),
    do: %{"exists" => state.exists?, "sha256" => state.sha256, "size" => state.size}

  defp digest(value), do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
end
