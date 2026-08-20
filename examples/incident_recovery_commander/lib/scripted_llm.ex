defmodule JidokaExamples.IncidentRecoveryCommander.ScriptedLLM do
  @moduledoc false

  alias Jidoka.{Cancellation, Config, Effect, Event, Stream}
  alias JidokaExamples.IncidentRecoveryCommander.IncidentState

  @primary "openai:incident-commander-primary"
  @fallback "anthropic:incident-commander-fallback"

  def primary, do: @primary
  def fallback, do: @fallback

  def capability(incident_id, incident_state) do
    fn %Effect.Intent{payload: payload} = intent, %Effect.Journal{} = journal, _context ->
      model = Config.model_ref(payload.model)
      agent_id = payload.agent_id
      IncidentState.record(incident_state, {:model_called, agent_id, model, llm_result_count(journal)})

      case agent_id do
        "durable_incident_recovery_commander" ->
          commander_decision(model, incident_id, journal)

        "incident_forensics_specialist" ->
          forensics_decision(incident_id, journal)

        "incident_containment_specialist" ->
          containment_decision(incident_id, journal)

        "incident_communications_specialist" ->
          communications_decision(incident_id, journal)

        other ->
          {:error, {:unsupported_incident_agent, other, intent.id}}
      end
    end
  end

  def streaming_brief(request_id, stream_to, incident_id) do
    fn %Effect.Intent{} = intent, _journal, _context ->
      sinks = [stream_to: stream_to]

      :ok =
        Stream.emit(
          Event.build(:llm_delta, [],
            request_id: request_id,
            effect_id: intent.id,
            effect_kind: :llm,
            data: %{chunk_type: :thinking, delta: "verify durable evidence "}
          ),
          sinks
        )

      content = "Incident #{incident_id} is resolved and all reviewed actions are durable."

      :ok =
        Stream.emit(
          Event.build(:llm_delta, [],
            request_id: request_id,
            effect_id: intent.id,
            effect_kind: :llm,
            data: %{chunk_type: :content, delta: content}
          ),
          sinks
        )

      {:ok,
       %{
         type: :final,
         content: content,
         result: resolved_result(incident_id)
       }}
    end
  end

  def cancellable(observer) do
    fn _intent, _journal, context ->
      send(observer, {:incident_cancellable_model_started, self()})
      wait_for_cancellation(context, 1_000)
    end
  end

  defp commander_decision(@primary, _incident_id, _journal), do: {:error, :timeout}

  defp commander_decision(@fallback, incident_id, journal) do
    case llm_result_count(journal) do
      0 -> {:ok, initial_operations(incident_id)}
      1 -> {:ok, final_decision(incident_id)}
    end
  end

  defp commander_decision(model, _incident_id, _journal),
    do: {:error, {:unsupported_incident_commander_model, model}}

  defp initial_operations(incident_id) do
    %{
      type: :operations,
      operations: [
        %{
          name: "load_incident_topology",
          arguments: %{"incident_id" => incident_id}
        },
        %{
          name: "forensics_specialist",
          arguments: %{
            "task" => "Find the cause of the payments-api failure.",
            "context" => %{"incident_id" => incident_id, "service" => "payments-api"}
          }
        },
        %{
          name: "containment_specialist",
          arguments: %{
            "task" => "Isolate payments-api under change ticket CHG-9001.",
            "context" => %{
              "change_ticket" => "CHG-9001",
              "incident_id" => incident_id,
              "service" => "payments-api"
            }
          }
        },
        %{
          name: "communications_specialist",
          arguments: %{
            "task" => "Publish the reviewed customer status update.",
            "context" => %{
              "incident_id" => incident_id,
              "message" => "Payment recovery is in progress. No data was lost."
            }
          }
        },
        %{
          name: "run_recovery_plan",
          arguments: %{
            "incident_id" => incident_id,
            "services" => ["checkout-api", "ledger-db", "payments-api"]
          }
        }
      ],
      metadata: %{
        finish_reason: :tool_calls,
        usage: %{input_tokens: 240, output_tokens: 90, total_cost: 0.01}
      }
    }
  end

  defp final_decision(incident_id) do
    content = "Incident #{incident_id} is resolved after reviewed containment, recovery, and communication."

    %{
      type: :final,
      content: content,
      result: resolved_result(incident_id),
      metadata: %{
        finish_reason: :stop,
        usage: %{input_tokens: 310, output_tokens: 70, total_cost: 0.012}
      }
    }
  end

  defp resolved_result(incident_id) do
    %{
      incident_id: incident_id,
      isolated_services: ["payments-api"],
      restored_services: ["payments-api", "checkout-api", "ledger-db"],
      status: :resolved,
      summary: "The dependency timeout was contained. All affected services recovered."
    }
  end

  defp forensics_decision(incident_id, journal) do
    if llm_result_count(journal) == 0 do
      {:ok,
       %{
         type: :operation,
         name: "collect_forensic_evidence",
         arguments: %{"incident_id" => incident_id, "service" => "payments-api"}
       }}
    else
      {:ok,
       %{
         type: :final,
         content: "The primary cause was connection pool exhaustion after a dependency timeout."
       }}
    end
  end

  defp containment_decision(incident_id, journal) do
    if llm_result_count(journal) == 0 do
      {:ok,
       %{
         type: :operation,
         name: "isolate_service",
         arguments: %{
           "change_ticket" => "CHG-9001",
           "incident_id" => incident_id,
           "service" => "payments-api"
         }
       }}
    else
      {:ok, %{type: :final, content: "payments-api was isolated under CHG-9001."}}
    end
  end

  defp communications_decision(incident_id, journal) do
    if llm_result_count(journal) == 0 do
      {:ok,
       %{
         type: :operation,
         name: "publish_status_update",
         arguments: %{
           "incident_id" => incident_id,
           "message" => "Payment recovery is in progress. No data was lost."
         }
       }}
    else
      {:ok, %{type: :final, content: "The reviewed incident update was published."}}
    end
  end

  defp llm_result_count(%Effect.Journal{} = journal) do
    Enum.count(journal.results, fn {_id, result} -> result.kind == :llm end)
  end

  defp wait_for_cancellation(_context, 0), do: {:error, :cancellation_not_received}

  defp wait_for_cancellation(context, attempts_left) do
    if Cancellation.requested?(context) do
      {:error, :cancelled}
    else
      Process.sleep(1)
      wait_for_cancellation(context, attempts_left - 1)
    end
  end
end
