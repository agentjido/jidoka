defmodule Jidoka.Controls.RequireApproval do
  @moduledoc """
  Built-in operation control used by approval sugar.

  Applications can still define custom controls. This module only handles the
  common case where a tool or request marks an operation as requiring human
  approval before execution.
  """

  use Jidoka.Control, name: "require_approval"

  alias Jidoka.Review.Policy
  alias Jidoka.Runtime.Controls.OperationContext

  @impl true
  def call(%OperationContext{metadata: metadata}) do
    policy =
      metadata
      |> policy_metadata()
      |> Policy.from_input()

    case policy do
      {:ok, %Policy{required: true} = policy} ->
        {:interrupt, policy.reason}

      {:ok, _policy} ->
        :cont

      {:error, reason} ->
        {:error, {:invalid_approval_policy, reason}}
    end
  end

  defp policy_metadata(metadata) when is_map(metadata) do
    Map.get(metadata, :policy) || Map.get(metadata, "policy") || %{}
  end
end
