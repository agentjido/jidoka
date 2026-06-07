defmodule Jidoka.Runtime.Review do
  @moduledoc """
  Runtime helpers for durable human review pauses.

  The public review structs live under `Jidoka.Review.*`. This module keeps the
  turn runner focused on orchestration by owning approval validation,
  approval-application, and review snapshot metadata.
  """

  alias Jidoka.Effect
  alias Jidoka.Review
  alias Jidoka.Turn

  @spec approval_response(keyword()) ::
          :missing | {:ok, Review.Response.t()} | {:error, {:invalid_approval_response, term()}}
  def approval_response(opts) do
    case Keyword.fetch(opts, :approval) do
      {:ok, approval} ->
        normalize_response(approval)

      :error ->
        case Keyword.fetch(opts, :approval_response) do
          {:ok, approval} -> normalize_response(approval)
          :error -> :missing
        end
    end
  end

  @spec approval_ttl_ms(keyword()) ::
          {:ok, pos_integer() | nil} | {:error, {:invalid_approval_ttl_ms, term()}}
  def approval_ttl_ms(opts) do
    case Keyword.get(opts, :approval_ttl_ms) do
      nil -> {:ok, nil}
      ttl_ms when is_integer(ttl_ms) and ttl_ms > 0 -> {:ok, ttl_ms}
      ttl_ms -> {:error, {:invalid_approval_ttl_ms, ttl_ms}}
    end
  end

  @spec put_pending_interrupt(
          Turn.State.t(),
          Review.Interrupt.t(),
          non_neg_integer(),
          pos_integer() | nil
        ) :: {:ok, Turn.State.t(), Review.Interrupt.t()}
  def put_pending_interrupt(
        %Turn.State{} = state,
        %Review.Interrupt{} = interrupt,
        now_ms,
        ttl_ms
      ) do
    interrupt = Review.Interrupt.with_review_window(interrupt, now_ms, ttl_ms)

    state =
      state
      |> Turn.State.put_pending_interrupt(interrupt)
      |> append_requested(interrupt)

    {:ok, state, interrupt}
  end

  @spec stamp_responded_at(Review.Response.t(), non_neg_integer()) :: Review.Response.t()
  def stamp_responded_at(%Review.Response{} = response, now_ms) do
    %Review.Response{response | responded_at_ms: now_ms}
  end

  @spec validate_response(Review.Interrupt.t(), Review.Response.t()) :: :ok | {:error, term()}
  def validate_response(
        %Review.Interrupt{id: interrupt_id, expires_at_ms: expires_at_ms},
        %Review.Response{interrupt_id: interrupt_id} = response
      ) do
    responded_at_ms = response.responded_at_ms || 0

    cond do
      is_integer(expires_at_ms) and responded_at_ms > expires_at_ms ->
        {:error, {:approval_expired, interrupt_id, responded_at_ms, expires_at_ms}}

      response.decision == :approved ->
        :ok

      response.decision == :denied ->
        {:error, {:approval_denied, response}}
    end
  end

  def validate_response(
        %Review.Interrupt{id: expected_interrupt_id},
        %Review.Response{interrupt_id: actual_interrupt_id}
      ) do
    {:error, {:approval_interrupt_mismatch, expected_interrupt_id, actual_interrupt_id}}
  end

  @spec apply_response(Turn.State.t(), Review.Interrupt.t(), Review.Response.t()) ::
          {:ok, Turn.State.t()} | {:error, term()}
  def apply_response(
        %Turn.State{} = state,
        %Review.Interrupt{} = interrupt,
        %Review.Response{decision: :approved} = response
      ) do
    with {:ok, state} <- mark_current_effect_approved(state, interrupt, response) do
      state =
        state
        |> Turn.State.clear_pending_interrupt()
        |> append_responded(interrupt, response)

      {:ok, state}
    end
  end

  @spec put_pending_metadata(map(), Review.Interrupt.t() | nil) :: map()
  def put_pending_metadata(metadata, nil), do: metadata

  def put_pending_metadata(metadata, %Review.Interrupt{} = interrupt) when is_map(metadata) do
    Map.put(metadata, "pending_review", Review.Request.from_interrupt!(interrupt))
  end

  defp normalize_response(response) do
    case Review.Response.from_input(response) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, {:invalid_approval_response, reason}}
    end
  end

  defp mark_current_effect_approved(
         %Turn.State{} = state,
         %Review.Interrupt{} = interrupt,
         response
       ) do
    case Enum.find(state.pending_effects, fn
           %Effect.Intent{id: effect_id} -> effect_id == interrupt.effect_id
           _other -> false
         end) do
      %Effect.Intent{} = effect ->
        metadata =
          effect.metadata
          |> Map.put("approved_interrupt_id", interrupt.id)
          |> Map.put("approval_decision", response.decision)

        {:ok, replace_pending_effect(state, %Effect.Intent{effect | metadata: metadata})}

      nil ->
        case Turn.State.current_pending_effect(state) do
          %Effect.Intent{} = effect ->
            {:error, {:approval_effect_mismatch, interrupt.effect_id, effect.id}}

          nil ->
            {:error, {:missing_pending_effect, state}}
        end
    end
  end

  defp replace_pending_effect(%Turn.State{} = state, %Effect.Intent{id: effect_id} = effect) do
    pending_effects =
      Enum.map(state.pending_effects, fn
        %Effect.Intent{id: ^effect_id} -> effect
        other -> other
      end)

    %Turn.State{state | pending_effects: pending_effects}
  end

  defp append_requested(%Turn.State{} = state, %Review.Interrupt{} = interrupt) do
    state
    |> Turn.Transition.new!()
    |> Turn.Transition.event(:approval_requested,
      agent_id: state.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index,
      operation: interrupt.operation,
      data: %{
        interrupt_id: interrupt.id,
        control: interrupt.control_name,
        operation: interrupt.operation,
        reason: interrupt.reason,
        expires_at_ms: interrupt.expires_at_ms
      }
    )
    |> Turn.Transition.commit()
  end

  defp append_responded(
         %Turn.State{} = state,
         %Review.Interrupt{} = interrupt,
         %Review.Response{} = response
       ) do
    state
    |> Turn.Transition.new!()
    |> Turn.Transition.event(:approval_responded,
      agent_id: state.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index,
      operation: interrupt.operation,
      data: %{
        interrupt_id: interrupt.id,
        decision: response.decision,
        reason: response.reason,
        responded_at_ms: response.responded_at_ms
      }
    )
    |> Turn.Transition.commit()
  end
end
