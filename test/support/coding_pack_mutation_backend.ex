defmodule Jidoka.TestSupport.CodingPackMutationBackend do
  @moduledoc false

  @behaviour Jidoka.CodingPack.MutationBackend

  alias Jidoka.ExecutionEnvironment.{Checkpoint, EnforcementEvidence}

  @digest "sha256:" <> String.duplicate("a", 64)

  @impl true
  def checkpoint(workspace, opts) do
    state = state(opts)
    ref = "test-checkpoint-#{System.unique_integer([:positive])}"
    snapshot = snapshot(workspace.root)
    Agent.update(state, &put_in(&1, [:snapshots, ref], snapshot))
    Agent.update(state, &Map.update(&1, :checkpoint_calls, 1, fn count -> count + 1 end))

    checkpoint =
      Checkpoint.new!(
        checkpoint_ref: ref,
        binding_revision: 0,
        profile_digest: @digest,
        evidence_digest: @digest,
        preserves: %{"files" => true},
        forkable: false,
        created_at_ms: 1
      )

    {:ok, checkpoint, evidence(state, :checkpoint)}
  end

  @impl true
  def inspect_file(workspace, relative, opts) do
    path = Path.join(workspace.root, relative)

    result =
      case File.read(path) do
        {:ok, content} ->
          %{exists?: true, content: content, sha256: digest(content), size: byte_size(content)}

        {:error, :enoent} ->
          %{exists?: false, content: nil, sha256: nil, size: 0}

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      {:error, reason} -> {:error, reason}
      state -> {:ok, state, evidence(state(opts), :read)}
    end
  end

  @impl true
  def replace_file(workspace, relative, content, opts) do
    state = state(opts)
    Agent.update(state, &Map.update(&1, :replace_calls, 1, fn count -> count + 1 end))
    path = Path.join(workspace.root, relative)
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".jidoka-test-tmp"

    case Agent.get(state, &Map.get(&1, :mode, :success)) do
      :fail_before_write ->
        {:error, :injected_failure}

      mode ->
        :ok = File.write(temporary, content)
        :ok = File.rename(temporary, path)
        final_state = %{exists?: true, content: content, sha256: digest(content), size: byte_size(content)}

        if mode == :partial_after_write,
          do: {:error, :injected_partial_failure, final_state, evidence(state, :write)},
          else: {:ok, %{method: :atomic_replace, final_state: final_state}, evidence(state, :write)}
    end
  end

  @impl true
  def restore(workspace, checkpoint, opts) do
    state = state(opts)
    snapshot = Agent.get(state, &get_in(&1, [:snapshots, checkpoint.checkpoint_ref]))

    if is_map(snapshot) do
      workspace.root
      |> File.ls!()
      |> Enum.each(&File.rm_rf!(Path.join(workspace.root, &1)))

      Enum.each(snapshot, fn {relative, content} ->
        path = Path.join(workspace.root, relative)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
      end)

      {:ok, evidence(state, :write)}
    else
      {:error, :unknown_checkpoint}
    end
  end

  defp state(opts), do: Keyword.fetch!(opts, :state)

  defp evidence(state, operation) do
    configured = Agent.get(state, &Map.get(&1, :evidence, %{}))

    facts = %{
      "path_confined" => true,
      "checkpoint" => true,
      "filesystem_read" => true,
      "filesystem_write" => true,
      "atomic_replace" => true,
      "operation" => Atom.to_string(operation)
    }

    EnforcementEvidence.new!(
      Map.merge(
        %{
          status: :confirmed,
          adapter_id: "test.coding",
          backend: "test",
          isolation: :container,
          network: :disabled,
          workspace: :isolated_copy,
          observed_at_ms: 1,
          facts: facts
        },
        configured
      )
    )
  end

  defp snapshot(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reduce(%{}, fn path, files ->
      case File.read(path) do
        {:ok, content} -> Map.put(files, Path.relative_to(path, root), content)
        {:error, _reason} -> files
      end
    end)
  end

  defp digest(value), do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
end
