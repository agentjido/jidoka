defmodule Jidoka.Memory do
  @moduledoc """
  Data contracts and runtime helpers for visible agent memory.
  """

  @type entry :: Jidoka.Memory.Entry.t()
  @type recall_request :: Jidoka.Memory.RecallRequest.t()
  @type recall_result :: Jidoka.Memory.RecallResult.t()
  @type write_request :: Jidoka.Memory.WriteRequest.t()
  @type write_result :: Jidoka.Memory.WriteResult.t()

  @doc """
  Recalls visible memory for a spec/request pair.

  This is the public facade over the runtime memory policy: it applies the
  spec's memory scope, namespace, session id, and max-entry settings before
  calling the configured memory store.
  """
  @spec recall(Jidoka.Agent.Spec.t(), Jidoka.Turn.Request.t(), keyword()) ::
          {:ok, recall_result() | nil} | {:error, term()}
  def recall(spec, request, opts \\ []), do: Jidoka.Memory.Runtime.recall(spec, request, opts)

  @doc """
  Writes one visible memory entry using the spec's memory policy.
  """
  @spec write(Jidoka.Agent.Spec.t(), String.t(), keyword()) ::
          {:ok, write_result()} | {:error, term()}
  def write(spec, content, opts \\ []), do: Jidoka.Memory.Runtime.write(spec, content, opts)

  @doc """
  Captures a completed turn into memory when the spec enables conversation capture.
  """
  @spec capture_turn(Jidoka.Agent.Spec.t(), Jidoka.Turn.Request.t(), Jidoka.Turn.Result.t(), keyword()) ::
          {:ok, write_result() | nil} | {:error, term()}
  def capture_turn(spec, request, result, opts \\ []),
    do: Jidoka.Memory.Runtime.capture_turn(spec, request, result, opts)
end
