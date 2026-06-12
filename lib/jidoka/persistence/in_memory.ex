defmodule Jidoka.Persistence.InMemory do
  @moduledoc """
  In-memory persistence adapter for tests and bootstrap implementations.

  The adapter keeps durable entities in maps keyed by id and stores per-session
  append-only event logs with stable monotonic ordering.
  """
  alias Jidoka.Attempt
  alias Jidoka.Artifact
  alias Jidoka.EnvironmentLease
  alias Jidoka.Event
  alias Jidoka.Outcome
  alias Jidoka.Persistence.{EventRecord, SessionEnvelope}
  alias Jidoka.Run
  alias Jidoka.Session
  alias Jidoka.VerificationResult

  @behaviour Jidoka.Persistence

  defstruct [
    :sessions,
    :runs,
    :attempts,
    :environment_leases,
    :artifacts,
    :verification_results,
    :outcomes,
    :events,
    :event_sequences
  ]

  @type t :: %__MODULE__{
          sessions: %{String.t() => Session.t()},
          runs: %{String.t() => Run.t()},
          attempts: %{String.t() => Attempt.t()},
          environment_leases: %{String.t() => EnvironmentLease.t()},
          artifacts: %{String.t() => Artifact.t()},
          verification_results: %{String.t() => VerificationResult.t()},
          outcomes: %{String.t() => Outcome.t()},
          events: %{String.t() => [EventRecord.t()]},
          event_sequences: %{String.t() => non_neg_integer()}
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    base = %__MODULE__{
      sessions: %{},
      runs: %{},
      attempts: %{},
      environment_leases: %{},
      artifacts: %{},
      verification_results: %{},
      outcomes: %{},
      events: %{},
      event_sequences: %{}
    }

    Enum.reduce(opts, base, fn
      {:sessions, values}, state when is_map(values) ->
        %{state | sessions: values}

      {:runs, values}, state when is_map(values) ->
        %{state | runs: values}

      {:attempts, values}, state when is_map(values) ->
        %{state | attempts: values}

      {:environment_leases, values}, state when is_map(values) ->
        %{state | environment_leases: values}

      {:artifacts, values}, state when is_map(values) ->
        %{state | artifacts: values}

      {:verification_results, values}, state when is_map(values) ->
        %{state | verification_results: values}

      {:outcomes, values}, state when is_map(values) ->
        %{state | outcomes: values}

      {:events, values}, state when is_map(values) ->
        %{state | events: values}

      {:event_sequences, values}, state when is_map(values) ->
        %{state | event_sequences: values}

      _other, state ->
        state
    end)
  end

  @impl true
  def save_session(%__MODULE__{} = state, %Session{} = session) do
    {:ok, put_record(state, :sessions, session.id, session)}
  end

  @impl true
  def load_session(%__MODULE__{} = state, session_id) when is_binary(session_id) do
    fetch_by_id(state.sessions, session_id)
  end

  @impl true
  def list_runs_for_session(%__MODULE__{} = state, session_id) when is_binary(session_id) do
    with {:ok, _session} <- load_session(state, session_id) do
      {:ok,
       state.runs
       |> Map.values()
       |> Enum.filter(&(&1.session_id == session_id))
       |> sort_by_created_at()}
    end
  end

  @impl true
  def save_run(%__MODULE__{} = state, %Run{} = run) do
    {:ok, put_record(state, :runs, run.id, run)}
  end

  @impl true
  def load_run(%__MODULE__{} = state, run_id) when is_binary(run_id) do
    fetch_by_id(state.runs, run_id)
  end

  @impl true
  def list_attempts_for_run(%__MODULE__{} = state, run_id) when is_binary(run_id) do
    with {:ok, _run} <- load_run(state, run_id) do
      {:ok,
       state.attempts
       |> Map.values()
       |> Enum.filter(&(&1.run_id == run_id))
       |> sort_by_created_at()}
    end
  end

  @impl true
  def list_attempts_for_session(%__MODULE__{} = state, session_id) when is_binary(session_id) do
    with {:ok, runs} <- list_runs_for_session(state, session_id) do
      run_ids = run_id_set(runs)

      {:ok,
       state.attempts
       |> Map.values()
       |> Enum.filter(&MapSet.member?(run_ids, &1.run_id))
       |> sort_by_created_at()}
    end
  end

  @impl true
  def save_attempt(%__MODULE__{} = state, %Attempt{} = attempt) do
    {:ok, put_record(state, :attempts, attempt.id, attempt)}
  end

  @impl true
  def load_attempt(%__MODULE__{} = state, attempt_id) when is_binary(attempt_id) do
    fetch_by_id(state.attempts, attempt_id)
  end

  @impl true
  def save_environment_lease(%__MODULE__{} = state, %EnvironmentLease{} = lease) do
    {:ok, put_record(state, :environment_leases, lease.id, lease)}
  end

  @impl true
  def load_environment_lease(%__MODULE__{} = state, lease_id) when is_binary(lease_id) do
    fetch_by_id(state.environment_leases, lease_id)
  end

  @impl true
  def list_environment_leases_for_session(
        %__MODULE__{} = state,
        session_id
      )
      when is_binary(session_id) do
    with {:ok, attempts} <- list_attempts_for_session(state, session_id) do
      attempt_ids = id_set(attempts)

      {:ok,
       state.environment_leases
       |> Map.values()
       |> Enum.filter(&MapSet.member?(attempt_ids, &1.attempt_id))
       |> sort_by_created_at()}
    end
  end

  @impl true
  def save_artifact(%__MODULE__{} = state, %Artifact{} = artifact) do
    {:ok, put_record(state, :artifacts, artifact.id, artifact)}
  end

  @impl true
  def load_artifact(%__MODULE__{} = state, artifact_id) when is_binary(artifact_id) do
    fetch_by_id(state.artifacts, artifact_id)
  end

  @impl true
  def list_artifacts_for_run(%__MODULE__{} = state, run_id) when is_binary(run_id) do
    with {:ok, _run} <- load_run(state, run_id) do
      {:ok,
       state.artifacts
       |> Map.values()
       |> Enum.filter(&(&1.run_id == run_id))
       |> sort_by_created_at()}
    end
  end

  @impl true
  def list_artifacts_for_session(%__MODULE__{} = state, session_id) when is_binary(session_id) do
    with {:ok, runs} <- list_runs_for_session(state, session_id) do
      run_ids = run_id_set(runs)
      attempt_ids = id_set(list_attempts_for_session_fast(state, run_ids))

      {:ok,
       state.artifacts
       |> Map.values()
       |> Enum.filter(fn artifact ->
         MapSet.member?(run_ids, artifact.run_id) or
           MapSet.member?(attempt_ids, artifact.attempt_id)
       end)
       |> sort_by_created_at()}
    end
  end

  @impl true
  def save_verification_result(%__MODULE__{} = state, %VerificationResult{} = result) do
    {:ok, put_record(state, :verification_results, result.id, result)}
  end

  @impl true
  def load_verification_result(%__MODULE__{} = state, result_id) when is_binary(result_id) do
    fetch_by_id(state.verification_results, result_id)
  end

  @impl true
  def list_verification_results_for_session(
        %__MODULE__{} = state,
        session_id
      )
      when is_binary(session_id) do
    with {:ok, attempts} <- list_attempts_for_session(state, session_id) do
      attempt_ids = id_set(attempts)

      {:ok,
       state.verification_results
       |> Map.values()
       |> Enum.filter(&MapSet.member?(attempt_ids, &1.attempt_id))
       |> sort_by_created_at()}
    end
  end

  @impl true
  def save_outcome(%__MODULE__{} = state, %Outcome{} = outcome) do
    {:ok, put_record(state, :outcomes, outcome.id, outcome)}
  end

  @impl true
  def load_outcome(%__MODULE__{} = state, outcome_id) when is_binary(outcome_id) do
    fetch_by_id(state.outcomes, outcome_id)
  end

  @impl true
  def list_outcomes_for_session(%__MODULE__{} = state, session_id) when is_binary(session_id) do
    with {:ok, runs} <- list_runs_for_session(state, session_id) do
      run_ids = run_id_set(runs)

      {:ok,
       state.outcomes
       |> Map.values()
       |> Enum.filter(&MapSet.member?(run_ids, &1.run_id))
       |> sort_by_created_at()}
    end
  end

  @impl true
  def append_event(%__MODULE__{} = state, %Event{} = event) when is_binary(event.session_id) do
    sequence =
      state.event_sequences
      |> Map.get(event.session_id, 0)
      |> Kernel.+(1)

    record = EventRecord.new(event.session_id, sequence, event)
    entries = Map.get(state.events, event.session_id, [])

    {:ok,
     %__MODULE__{
       state
       | events: Map.put(state.events, event.session_id, entries ++ [record]),
         event_sequences: Map.put(state.event_sequences, event.session_id, sequence)
     }, record}
  end

  def append_event(_, %Event{session_id: session_id})
      when is_binary(session_id) do
    {:error, {:invalid_state, session_id, :not_a_memory_store}}
  end

  def append_event(_, _), do: {:error, :invalid_event}

  @impl true
  def list_events_for_session(%__MODULE__{} = state, session_id) when is_binary(session_id) do
    with {:ok, _session} <- load_session(state, session_id) do
      {:ok, Map.get(state.events, session_id, [])}
    end
  end

  @impl true
  def load_session_envelope(%__MODULE__{} = state, session_id) when is_binary(session_id) do
    with {:ok, session} <- load_session(state, session_id),
         {:ok, runs} <- list_runs_for_session(state, session_id),
         {:ok, attempts} <- list_attempts_for_session(state, session_id),
         {:ok, leases} <- list_environment_leases_for_session(state, session_id),
         {:ok, artifacts} <- list_artifacts_for_session(state, session_id),
         {:ok, verification_results} <- list_verification_results_for_session(state, session_id),
         {:ok, outcomes} <- list_outcomes_for_session(state, session_id),
         {:ok, events} <- list_events_for_session(state, session_id) do
      {:ok,
       %SessionEnvelope{
         session: session,
         runs: runs,
         attempts: attempts,
         leases: leases,
         artifacts: artifacts,
         verification_results: verification_results,
         outcomes: outcomes,
         events: events
       }}
    end
  end

  defp put_record(%__MODULE__{} = state, :sessions, id, record),
    do: %{state | sessions: Map.put(state.sessions, id, record)}

  defp put_record(%__MODULE__{} = state, :runs, id, record),
    do: %{state | runs: Map.put(state.runs, id, record)}

  defp put_record(%__MODULE__{} = state, :attempts, id, record),
    do: %{state | attempts: Map.put(state.attempts, id, record)}

  defp put_record(%__MODULE__{} = state, :environment_leases, id, record),
    do: %{state | environment_leases: Map.put(state.environment_leases, id, record)}

  defp put_record(%__MODULE__{} = state, :artifacts, id, record),
    do: %{state | artifacts: Map.put(state.artifacts, id, record)}

  defp put_record(%__MODULE__{} = state, :verification_results, id, record),
    do: %{state | verification_results: Map.put(state.verification_results, id, record)}

  defp put_record(%__MODULE__{} = state, :outcomes, id, record),
    do: %{state | outcomes: Map.put(state.outcomes, id, record)}

  defp fetch_by_id(records, id) do
    case Map.fetch(records, id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
  end

  defp run_id_set(runs), do: MapSet.new(Enum.map(runs, & &1.id))

  defp id_set(records), do: MapSet.new(Enum.map(records, & &1.id))

  defp list_attempts_for_session_fast(state, run_ids) do
    state.attempts
    |> Map.values()
    |> Enum.filter(&MapSet.member?(run_ids, &1.run_id))
  end

  defp sort_by_created_at(records) do
    Enum.sort_by(records, & &1.created_at, DateTime)
  end
end
