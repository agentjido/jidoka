defmodule Jidoka.Controls.RequireApproval do
  @moduledoc """
  Built-in operation control used by approval sugar.

  Applications can still define custom controls. This module only handles the
  common case where a tool or request marks an operation as requiring human
  approval before execution.
  """

  use Jidoka.Control, name: "require_approval"

  alias Jidoka.ApprovalPredicate
  alias Jidoka.Review.Policy
  alias Jidoka.Runtime.Controls.OperationContext

  @impl true
  def call(%OperationContext{metadata: metadata, ctx: ctx}) do
    with {:ok, policy} <- metadata |> policy_metadata() |> Policy.from_input(),
         {:ok, applies?} <- approval_applies?(policy, ctx) do
      case {policy, applies?} do
        {%Policy{required: true} = policy, true} -> {:interrupt, policy.reason}
        {_policy, _applies?} -> :cont
      end
    else
      {:error, reason} -> {:error, {:invalid_approval_policy, reason}}
    end
  end

  defp approval_applies?(%Policy{predicate: predicate}, %Jidoka.Context{} = ctx) do
    ApprovalPredicate.evaluate(predicate, ctx)
  end

  defp approval_applies?(%Policy{}, _ctx), do: {:ok, true}
  defp approval_applies?(nil, _ctx), do: {:ok, false}

  defp policy_metadata(metadata) when is_map(metadata) do
    Map.get(metadata, :policy) || Map.get(metadata, "policy") || %{}
  end

  defp policy_metadata(_metadata), do: %{}
end
