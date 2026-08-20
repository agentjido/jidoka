defmodule Jidoka.Adapter.Runic.Workflow.SnapshotState do
  @moduledoc false

  alias Jidoka.Context
  alias Jidoka.Workflow.Snapshot
  alias Jidoka.Workflow.Spec

  @snapshot_schema_version Snapshot.schema_version()

  @spec build(Spec.t(), map()) :: Snapshot.t()
  def build(%Spec{} = spec, state) when is_map(state) do
    %Snapshot{
      schema_version: Snapshot.schema_version(),
      workflow: spec.module,
      workflow_id: spec.id,
      input: state.input,
      context: Context.data(state.context),
      steps: state.steps,
      outcomes: state.outcomes
    }
  end

  @spec validate(Snapshot.t(), Spec.t()) :: :ok | {:error, term()}
  def validate(
        %Snapshot{
          schema_version: version,
          workflow: workflow,
          workflow_id: id
        } = snapshot,
        %Spec{module: workflow, id: id, steps: steps}
      )
      when version == @snapshot_schema_version do
    with {:ok, %Jidoka.Workflow.Loop.Cursor{step: step, max_iterations: max_iterations}} <-
           Snapshot.cursor(snapshot) do
      case Enum.find(steps, &(&1.name == step)) do
        %{kind: :loop, max_iterations: ^max_iterations} ->
          :ok

        %{kind: :loop, max_iterations: current} ->
          {:error, {:workflow_loop_bound_changed, step, max_iterations, current}}

        _step ->
          {:error, {:workflow_snapshot_loop_missing, step}}
      end
    end
  end

  def validate(%Snapshot{} = snapshot, %Spec{} = spec) do
    {:error,
     {:workflow_snapshot_mismatch,
      %{
        snapshot: %{
          schema_version: snapshot.schema_version,
          workflow: snapshot.workflow,
          workflow_id: snapshot.workflow_id
        },
        current: %{
          schema_version: Snapshot.schema_version(),
          workflow: spec.module,
          workflow_id: spec.id
        }
      }}}
  end
end
