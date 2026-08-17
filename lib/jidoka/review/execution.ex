defmodule Jidoka.Review.Execution do
  @moduledoc """
  Application use cases for pending reviews and review responses.

  Review data stays in `Jidoka.Review.*` contracts. This module coordinates a
  response with turn or session execution.
  """

  alias Jidoka.Review
  alias Jidoka.Error
  alias Jidoka.Session.Data
  alias Jidoka.Session.Execution, as: SessionExecution
  alias Jidoka.Session.Store
  alias Jidoka.Snapshot
  alias Jidoka.Turn.Execution, as: TurnExecution

  @type target :: Snapshot.t() | Data.t() | String.t()
  @type result ::
          TurnExecution.result()
          | SessionExecution.session_run_result()

  @doc "Lists pending reviews from a snapshot, session, session ID, or store."
  @spec pending(Snapshot.t() | Data.t() | Store.store() | String.t()) ::
          {:ok, [Review.Request.t()]} | {:error, term()}
  def pending(%Data{} = session), do: {:ok, Data.pending_reviews(session)}
  def pending(%Snapshot{} = snapshot), do: pending_from_snapshot(snapshot)

  def pending(snapshot_input) when is_binary(snapshot_input) do
    with {:ok, snapshot} <- Snapshot.from_input(snapshot_input) do
      pending_from_snapshot(snapshot)
    end
  end

  def pending(store), do: Store.pending_reviews(store)

  @doc "Approves one review and resumes its target."
  @spec approve(target(), Review.Request.t() | String.t(), keyword()) :: result()
  def approve(target, review_or_id, opts \\ []) do
    response = Review.Response.approve(review_or_id, response_opts(opts))
    resume_target(target, response, opts)
  end

  @doc "Denies one review and resumes its target."
  @spec deny(target(), Review.Request.t() | String.t(), keyword()) :: result()
  def deny(target, review_or_id, opts \\ []) do
    response = Review.Response.deny(review_or_id, response_opts(opts))
    resume_target(target, response, opts)
  end

  defp pending_from_snapshot(%Snapshot{} = snapshot), do: {:ok, Data.pending_reviews(snapshot)}

  defp resume_target(%Data{} = session, %Review.Response{} = response, opts) do
    SessionExecution.resume_session(session, resume_opts(opts, response))
  end

  defp resume_target(snapshot_input, %Review.Response{} = response, opts) do
    case TurnExecution.resume(snapshot_input, resume_opts(opts, response)) do
      {:ok, _result} = ok -> ok
      {:hibernate, _snapshot} = hibernate -> hibernate
      {:error, reason} -> {:error, Error.normalize(reason, operation: :resume, phase: :harness)}
    end
  end

  defp response_opts(opts), do: Keyword.take(opts, [:reason, :responded_at_ms, :metadata])

  defp resume_opts(opts, response) do
    opts
    |> Keyword.drop([:reason, :responded_at_ms, :metadata])
    |> Keyword.put(:approval, response)
  end
end
