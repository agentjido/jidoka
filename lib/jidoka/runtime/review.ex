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

  @progress_key "approval_progress"

  @doc "Reads and normalizes an optional approval response from runtime options."
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

  @doc "Reads and validates the optional approval time-to-live value."
  @spec approval_ttl_ms(keyword()) ::
          {:ok, pos_integer() | nil} | {:error, {:invalid_approval_ttl_ms, term()}}
  def approval_ttl_ms(opts) do
    case Keyword.get(opts, :approval_ttl_ms) do
      nil -> {:ok, nil}
      ttl_ms when is_integer(ttl_ms) and ttl_ms > 0 -> {:ok, ttl_ms}
      ttl_ms -> {:error, {:invalid_approval_ttl_ms, ttl_ms}}
    end
  end

  @doc "Stores a pending interrupt and its public review metadata on turn state."
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

  @doc "Adds a response time when the response does not already have one."
  @spec stamp_responded_at(Review.Response.t(), non_neg_integer()) :: Review.Response.t()
  def stamp_responded_at(%Review.Response{} = response, now_ms) do
    %Review.Response{response | responded_at_ms: now_ms}
  end

  @doc "Validates response identity, expiry, and permitted decisions."
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

  @doc "Applies a valid approval or denial response to turn state."
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

  @doc "Builds a stable identity for one exact review gate."
  @spec gate_id([term()]) :: String.t()
  def gate_id(parts) when is_list(parts) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(parts))
      |> Base.url_encode64(padding: false)

    "gate:" <> digest
  end

  @doc "Returns true when one exact gate completed for this intent."
  @spec gate_completed?(Effect.Intent.t(), String.t()) :: boolean()
  def gate_completed?(%Effect.Intent{} = intent, gate_id) when is_binary(gate_id) do
    Enum.any?(progress(intent), fn entry ->
      entry["intent_id"] == intent.id and entry["gate_id"] == gate_id and
        entry["status"] == "completed"
    end)
  end

  @doc "Returns true when an approval matches one exact gate and interrupt."
  @spec approved_gate?(Effect.Intent.t(), String.t(), String.t()) :: boolean()
  def approved_gate?(%Effect.Intent{} = intent, gate_id, interrupt_id)
      when is_binary(gate_id) and is_binary(interrupt_id) do
    Enum.any?(progress(intent), fn entry ->
      entry["intent_id"] == intent.id and entry["gate_id"] == gate_id and
        entry["interrupt_id"] == interrupt_id and entry["status"] == "approved"
    end)
  end

  @doc "Returns true when exact gate progress permits an incomplete reviewed effect to resume."
  @spec resumable_approval?(Effect.Intent.t()) :: boolean()
  def resumable_approval?(%Effect.Intent{} = intent) do
    Enum.any?(progress(intent), fn entry ->
      entry["intent_id"] == intent.id and entry["approved"] == true
    end)
  end

  @doc "Marks one exact gate as complete on the pending intent."
  @spec complete_gate(Turn.State.t(), Effect.Intent.t(), String.t()) :: Turn.State.t()
  def complete_gate(%Turn.State{} = state, %Effect.Intent{} = intent, gate_id)
      when is_binary(gate_id) do
    intent = Enum.find(state.pending_effects, &(&1.id == intent.id)) || intent
    existing = Enum.find(progress(intent), &(&1["intent_id"] == intent.id and &1["gate_id"] == gate_id))

    entry = %{
      "intent_id" => intent.id,
      "gate_id" => gate_id,
      "interrupt_id" => if(existing, do: existing["interrupt_id"]),
      "approved" => not is_nil(existing) and existing["approved"] == true,
      "status" => "completed"
    }

    put_progress(state, intent, entry)
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
         _response
       ) do
    case Enum.find(state.pending_effects, fn
           %Effect.Intent{id: effect_id} -> effect_id == interrupt.effect_id
           _other -> false
         end) do
      %Effect.Intent{} = effect ->
        case interrupt_gate_id(interrupt) do
          gate_id when is_binary(gate_id) ->
            entry = %{
              "intent_id" => effect.id,
              "gate_id" => gate_id,
              "interrupt_id" => interrupt.id,
              "approved" => true,
              "status" => "approved"
            }

            {:ok, put_progress(state, effect, entry)}

          nil ->
            {:error, {:approval_gate_identity_missing, interrupt.id}}
        end

      nil ->
        case Turn.State.current_pending_effect(state) do
          %Effect.Intent{} = effect ->
            {:error, {:approval_effect_mismatch, interrupt.effect_id, effect.id}}

          nil ->
            {:error, {:missing_pending_effect, state}}
        end
    end
  end

  defp progress(%Effect.Intent{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, @progress_key, Map.get(metadata, :approval_progress)) do
      entries when is_list(entries) -> Enum.filter(entries, &is_map/1)
      _legacy_or_missing -> []
    end
  end

  defp put_progress(%Turn.State{} = state, %Effect.Intent{} = effect, entry) do
    entries =
      effect
      |> progress()
      |> Enum.reject(&(&1["intent_id"] == entry["intent_id"] and &1["gate_id"] == entry["gate_id"]))
      |> Kernel.++([entry])

    metadata = Map.put(effect.metadata, @progress_key, entries)
    replace_pending_effect(state, %Effect.Intent{effect | metadata: metadata})
  end

  defp interrupt_gate_id(%Review.Interrupt{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "gate_id") || Map.get(metadata, :gate_id)
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
