defmodule Jidoka.Policy.Gate do
  @moduledoc """
  Authoritative host gate for protected external effects.

  The runtime records a decision before it calls the protected capability. The
  default host policy allows normal model and operation effects for backward
  compatibility. It denies environment and process-extension effects unless a
  host supplies an explicit policy capability. Human review is defined only
  for operation effects; a review decision for another effect kind fails closed.
  """

  alias Jidoka.Cancellation
  alias Jidoka.Cancellation.Token
  alias Jidoka.Context
  alias Jidoka.Effect
  alias Jidoka.Error
  alias Jidoka.Policy.Decision
  alias Jidoka.Policy.Request
  alias Jidoka.Review.Interrupt
  alias Jidoka.Runtime.EffectTrace
  alias Jidoka.Runtime.Review, as: RuntimeReview
  alias Jidoka.Turn

  @task_supervisor Jidoka.Runtime.TaskSupervisor

  @type capability :: (Request.t(), Context.t() -> {:ok, Decision.t() | map()} | {:error, term()})

  @doc "Returns the built-in compatibility decision for model and operation effects."
  @spec default(Request.t(), Context.t()) :: {:ok, Decision.t()}
  def default(%Request{effect_class: effect_class}, %Context{})
      when effect_class in [:llm, :operation] do
    {:ok,
     Decision.new!(
       outcome: :allow,
       rule_id: "jidoka.default.#{effect_class}",
       evidence: %{"source" => "jidoka_builtin"}
     )}
  end

  def default(%Request{effect_class: effect_class}, %Context{}) do
    {:ok,
     Decision.new!(
       outcome: :deny,
       rule_id: "jidoka.default.fail_closed",
       reason: {:explicit_host_policy_required, effect_class},
       evidence: %{"source" => "jidoka_builtin"}
     )}
  end

  @doc "Returns a missing-capability error for fail-closed tests and host validation."
  @spec missing(Request.t(), Context.t()) :: {:error, :missing_policy_capability}
  def missing(%Request{}, %Context{}), do: {:error, :missing_policy_capability}

  @doc "Checks one turn effect and records its authoritative decision."
  @spec authorize(Turn.State.t(), Effect.Intent.t(), capability(), keyword()) ::
          {:allow, Decision.t(), Turn.State.t()}
          | {:deny, Decision.t(), Turn.State.t()}
          | {:review, Decision.t(), Interrupt.t(), Turn.State.t()}
          | {:error, term()}
  def authorize(%Turn.State{} = state, %Effect.Intent{} = intent, policy, opts)
      when is_function(policy, 2) and is_list(opts) do
    case Effect.Journal.policy_decision_for(state.journal, intent) do
      %Decision{} = decision -> apply_decision(state, intent, decision, opts)
      nil -> request_decision(state, intent, policy, opts)
    end
  end

  def authorize(%Turn.State{}, %Effect.Intent{}, _policy, _opts),
    do: {:error, :missing_policy_capability}

  @doc "Checks a standalone protected lifecycle request."
  @spec check(Request.t(), capability(), keyword()) :: {:ok, Decision.t()} | {:error, term()}
  def check(request, policy, opts \\ [])

  def check(%Request{} = request, policy, opts) when is_function(policy, 2) do
    context = Context.from_data!(%{"request_id" => request.request_id})

    with {:ok, %Decision{} = decision} <- invoke(policy, request, context, opts),
         :ok <- allowed(request, decision) do
      {:ok, stamp(decision, opts)}
    else
      {:error, _reason} = error -> error
    end
  end

  def check(%Request{}, _policy, _opts), do: {:error, :missing_policy_capability}

  defp request_decision(%Turn.State{} = state, intent, policy, opts) do
    request = build_request(state, intent)
    context = Context.from_data!(Context.data(state.request.context))

    with {:ok, %Decision{} = decision} <- invoke(policy, request, context, opts) do
      decision = stamp(decision, opts)
      journal = Effect.Journal.put_policy_decision(state.journal, intent, decision)
      apply_decision(%Turn.State{state | journal: journal}, intent, decision, opts)
    else
      {:error, reason} -> {:error, {:policy_check_failed, request.effect_class, reason}}
    end
  end

  defp apply_decision(state, intent, %Decision{outcome: :allow} = decision, opts) do
    {:allow, decision, append_decision_event(state, intent, decision, :policy_allowed, opts)}
  end

  defp apply_decision(state, intent, %Decision{outcome: :deny} = decision, opts) do
    {:deny, decision, append_decision_event(state, intent, decision, :policy_denied, opts)}
  end

  defp apply_decision(state, intent, %Decision{outcome: :consent_required} = decision, opts) do
    {:deny, decision, append_decision_event(state, intent, decision, :policy_consent_required, opts)}
  end

  defp apply_decision(state, intent, %Decision{outcome: :unsupported} = decision, opts) do
    {:deny, decision, append_decision_event(state, intent, decision, :policy_unsupported, opts)}
  end

  defp apply_decision(
         state,
         %Effect.Intent{kind: :operation} = intent,
         %Decision{outcome: :require_review} = decision,
         opts
       ) do
    interrupt = review_interrupt(state, intent, decision)
    gate_id = interrupt.metadata["gate_id"]
    intent = current_intent(state, intent)

    cond do
      RuntimeReview.gate_completed?(intent, gate_id) ->
        {:allow, decision, append_decision_event(state, intent, decision, :policy_allowed, opts)}

      RuntimeReview.approved_gate?(intent, gate_id, interrupt.id) ->
        state = RuntimeReview.complete_gate(state, intent, gate_id)
        {:allow, decision, append_decision_event(state, intent, decision, :policy_allowed, opts)}

      true ->
        state = append_decision_event(state, intent, decision, :policy_review_requested, opts)
        {:review, decision, interrupt, state}
    end
  end

  defp apply_decision(
         _state,
         %Effect.Intent{kind: effect_kind},
         %Decision{outcome: :require_review},
         _opts
       ) do
    {:error, {:unsupported_policy_decision, :require_review, effect_kind}}
  end

  defp build_request(state, %Effect.Intent{kind: kind} = intent) do
    Request.new!(
      effect_class: kind,
      action: action(intent),
      resource: resource(state, intent),
      session_id: metadata_value(state.request.metadata, :session_id),
      request_id: EffectTrace.request_id(state, intent),
      intent_id: intent.id,
      advice: metadata_value(intent.metadata, :policy_advice) || %{},
      metadata: %{"agent_id" => state.plan.spec.id, "loop_index" => state.loop_index}
    )
  end

  defp action(%Effect.Intent{kind: :operation} = intent), do: EffectTrace.operation(intent) || "operation"
  defp action(%Effect.Intent{kind: :llm}), do: "model.invoke"

  defp resource(state, %Effect.Intent{kind: :operation, payload: payload}) do
    arguments = Map.get(payload, :arguments) || Map.get(payload, "arguments") || %{}

    base = %{
      "operation" => Map.get(payload, :name) || Map.get(payload, "name"),
      "argument_keys" => arguments |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    }

    Map.merge(base, declared_resource(state, base["operation"], arguments))
  end

  defp resource(_state, %Effect.Intent{kind: :llm}), do: %{"class" => "model"}

  defp declared_resource(state, operation_name, arguments) do
    state.plan.spec.operations
    |> Enum.find(&(&1.name == operation_name))
    |> case do
      %{metadata: metadata} when is_map(metadata) ->
        metadata
        |> metadata_value(:policy_resource)
        |> declared_resource_arguments(arguments)

      _operation ->
        %{}
    end
  end

  defp declared_resource_arguments(resource, arguments) when is_map(resource) do
    fields = metadata_value(resource, :argument_fields) || []

    selected =
      fields
      |> Enum.reduce(%{}, fn field, selected ->
        case portable_argument(arguments, field) do
          {:ok, value} -> Map.put(selected, to_string(field), value)
          :error -> selected
        end
      end)

    resource
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.delete("argument_fields")
    |> Map.put("arguments", selected)
  end

  defp declared_resource_arguments(_resource, _arguments), do: %{}

  defp portable_argument(arguments, field) do
    case fetch_argument(arguments, field) do
      {:ok, value} when is_binary(value) and byte_size(value) <= 1_024 -> {:ok, value}
      {:ok, value} when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value) -> {:ok, value}
      _result -> :error
    end
  end

  defp fetch_argument(arguments, field) do
    case Map.fetch(arguments, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(arguments, to_string(field))
    end
  end

  defp stamp(%Decision{decided_at_ms: nil} = decision, opts),
    do: %Decision{decision | decided_at_ms: clock_ms(opts)}

  defp stamp(%Decision{} = decision, _opts), do: decision

  defp allowed(_request, %Decision{outcome: :allow}), do: :ok
  defp allowed(_request, %Decision{outcome: :deny, reason: reason}), do: {:error, {:policy_denied, reason}}

  defp allowed(_request, %Decision{outcome: :consent_required, reason: reason}),
    do: {:error, {:policy_consent_required, reason}}

  defp allowed(_request, %Decision{outcome: :unsupported, reason: reason}),
    do: {:error, {:policy_unsupported, reason}}

  defp allowed(%Request{effect_class: :operation}, %Decision{outcome: :require_review}),
    do: {:error, :policy_review_required}

  defp allowed(%Request{effect_class: effect_kind}, %Decision{outcome: :require_review}),
    do: {:error, {:unsupported_policy_decision, :require_review, effect_kind}}

  defp invoke(policy, request, context, opts) do
    with :ok <- Cancellation.check(opts) do
      task = Task.Supervisor.async_nolink(@task_supervisor, fn -> safe_call(policy, request, context) end)
      maybe_register(task, opts)
      timeout = policy_timeout(opts)

      case Task.yield(task, timeout) do
        {:ok, result} ->
          result

        {:exit, reason} ->
          invalid_policy_result(:task_exit, reason)

        nil ->
          _result = Task.shutdown(task, :brutal_kill)
          {:error, {:policy_timeout, timeout}}
      end
    end
  end

  defp safe_call(policy, request, context) do
    policy.(request, context)
    |> normalize_policy_result()
  rescue
    exception -> invalid_policy_result(:exception, exception)
  catch
    kind, reason -> invalid_policy_result(kind, reason)
  end

  defp normalize_policy_result({:ok, output}) do
    case Decision.new(output) do
      {:ok, %Decision{} = decision} -> {:ok, decision}
      {:error, reason} -> invalid_policy_result(:decision, reason)
    end
  end

  defp normalize_policy_result({:error, reason}), do: {:error, reason}
  defp normalize_policy_result(output), do: invalid_policy_result(:return, output)

  defp invalid_policy_result(kind, cause) do
    {:error, {:invalid_policy_callback_result, kind, Error.to_map(cause)}}
  end

  defp maybe_register(%Task{pid: pid}, opts) do
    case Keyword.get(opts, :cancellation) do
      %Token{} = token -> Token.register(token, pid)
      _token -> :ok
    end
  end

  defp append_decision_event(state, intent, decision, event, opts) do
    data = %{
      policy_version: decision.version,
      policy_outcome: decision.outcome,
      policy_rule_id: decision.rule_id,
      policy_evidence: decision.evidence
    }

    EffectTrace.append(state, intent, event, [data: data], opts)
  end

  defp review_interrupt(state, intent, decision) do
    operation = EffectTrace.operation(intent) || action(intent)
    gate_id = RuntimeReview.gate_id([intent.id, :host_policy_gate, decision.rule_id])

    Interrupt.new!(
      id: Interrupt.stable_id([state.plan.spec.id, state.request.request_id, intent.id, gate_id, decision.rule_id]),
      boundary: :operation,
      control: __MODULE__,
      control_name: "host_policy_gate",
      reason: decision.reason || :policy_review_required,
      agent_id: state.plan.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index,
      effect_id: intent.id,
      effect_kind: :operation,
      operation: operation,
      arguments: %{},
      idempotency: intent.idempotency,
      idempotency_key: intent.idempotency_key,
      metadata: %{"gate_id" => gate_id, "policy_rule_id" => decision.rule_id}
    )
  end

  defp current_intent(state, fallback) do
    Enum.find(state.pending_effects, &(&1.id == fallback.id)) || fallback
  end

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))

  defp policy_timeout(opts) do
    case Keyword.get(opts, :policy_timeout_ms, 5_000) do
      value when is_integer(value) and value > 0 -> value
      _value -> 5_000
    end
  end

  defp clock_ms(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _clock -> System.system_time(:millisecond)
    end
  end
end
