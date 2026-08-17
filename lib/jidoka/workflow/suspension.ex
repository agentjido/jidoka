defmodule Jidoka.Workflow.Suspension do
  @moduledoc false

  alias Jidoka.Workflow.Loop.Cursor

  @type lookup :: {:ok, nil | {atom(), Cursor.t()}} | {:error, term()}

  @doc false
  @spec find(map()) :: lookup()
  def find(outcomes) when is_map(outcomes) do
    suspended =
      outcomes
      |> Enum.filter(fn {_step, outcome} -> match?(%{status: :suspended}, outcome) end)
      |> Enum.sort_by(fn {step, _outcome} -> step end)

    case suspended do
      [] ->
        {:ok, nil}

      [{step, %{cursor: %Cursor{step: step} = cursor}}] ->
        {:ok, {step, cursor}}

      [{step, %{cursor: %Cursor{step: cursor_step}}}] ->
        {:error, {:workflow_suspension_step_mismatch, step, cursor_step}}

      [{step, outcome}] ->
        {:error, {:invalid_workflow_suspension_outcome, step, outcome}}

      suspended ->
        {:error, {:multiple_workflow_suspensions, Enum.map(suspended, &elem(&1, 0))}}
    end
  end

  def find(outcomes), do: {:error, {:invalid_workflow_outcomes, outcomes}}

  @doc false
  @spec cursor(map()) :: {:ok, Cursor.t() | nil} | {:error, term()}
  def cursor(outcomes) do
    case find(outcomes) do
      {:ok, nil} -> {:ok, nil}
      {:ok, {_step, cursor}} -> {:ok, cursor}
      {:error, _reason} = error -> error
    end
  end
end
