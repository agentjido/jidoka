defmodule Jidoka.Replay.Recorder do
  @moduledoc "Ordered capability fixture recorder and fail-closed replay player."

  use GenServer

  alias Jidoka.Replay.Codec
  alias Jidoka.Replay.Fixture
  alias Jidoka.Replay.Fixture.Entry

  @type controller :: GenServer.server()

  @doc "Starts an empty recorder."
  @spec start_recording(keyword()) :: GenServer.on_start()
  def start_recording(opts \\ []) do
    with :ok <- validate_options(opts) do
      GenServer.start_link(__MODULE__, {:record, opts})
    end
  end

  @doc "Starts a replay player after fixture and compatibility validation."
  @spec start_replay(Fixture.t() | map(), keyword()) :: GenServer.on_start()
  def start_replay(fixture, opts \\ []) do
    with {:ok, fixture} <- Fixture.new(fixture),
         :ok <- validate_options(opts),
         :ok <- compatible(fixture.compatibility, Keyword.get(opts, :compatibility, %{})) do
      GenServer.start_link(__MODULE__, {:replay, fixture, opts})
    end
  end

  @doc "Records or replays one normalized capability call."
  @spec capture(controller(), atom() | String.t(), atom() | String.t(), term(), (-> term())) :: term()
  def capture(controller, class, action, request, function) when is_function(function, 0) do
    class = to_string(class)
    action = to_string(action)

    case Codec.encode(request) do
      {:ok, encoded_request} ->
        fingerprint = Codec.digest(%{"class" => class, "action" => action, "request" => encoded_request})

        case mode(controller) do
          :record -> record_call(controller, class, action, fingerprint, function)
          :replay -> replay_call(controller, class, action, fingerprint)
        end

      {:error, reason} ->
        {:error, {:capability_fixture_request_rejected, reason}}
    end
  end

  @doc "Returns the current verified recording fixture."
  @spec fixture(controller()) :: {:ok, Fixture.t()} | {:error, term()}
  def fixture(controller), do: GenServer.call(controller, :fixture)

  @doc "Checks that replay consumed every entry."
  @spec finish(controller()) :: :ok | {:error, term()}
  def finish(controller), do: GenServer.call(controller, :finish)

  @doc "Returns portable fixture provenance."
  @spec provenance(controller()) :: map()
  def provenance(controller), do: GenServer.call(controller, :provenance)

  @impl true
  def init({:record, opts}) do
    {:ok,
     %{
       mode: :record,
       opts: recording_opts(opts),
       compatibility: Keyword.get(opts, :compatibility, %{}),
       entries: %{},
       next_index: 1,
       occurrences: %{}
     }}
  end

  def init({:replay, %Fixture{} = fixture, opts}) do
    {:ok, %{mode: :replay, opts: recording_opts(opts), fixture: fixture, cursor: 0}}
  end

  @impl true
  def handle_call(:mode, _from, state), do: {:reply, state.mode, state}
  def handle_call(:options, _from, state), do: {:reply, state.opts, state}

  def handle_call({:reserve, class, action, fingerprint}, _from, %{mode: :record} = state) do
    key = {class, action, fingerprint}
    occurrence = Map.get(state.occurrences, key, 0) + 1
    index = state.next_index

    {:reply, {index, occurrence},
     %{state | next_index: index + 1, occurrences: Map.put(state.occurrences, key, occurrence)}}
  end

  def handle_call({:commit, %Entry{} = entry}, _from, %{mode: :record} = state) do
    {:reply, :ok, %{state | entries: Map.put(state.entries, entry.index, entry)}}
  end

  def handle_call({:replay, class, action, fingerprint}, _from, %{mode: :replay} = state) do
    actual = %{"class" => class, "action" => action, "fingerprint" => fingerprint, "index" => state.cursor + 1}

    case Enum.at(state.fixture.entries, state.cursor) do
      nil ->
        {:reply, {:error, {:capability_replay_missing_call, actual}}, state}

      %Entry{} = expected ->
        if {expected.class, expected.action, expected.fingerprint} == {class, action, fingerprint} do
          {:reply, {:ok, expected.response}, %{state | cursor: state.cursor + 1}}
        else
          expected = Map.take(Entry.to_map(expected), ["index", "class", "action", "fingerprint", "occurrence"])
          {:reply, {:error, {:capability_replay_mismatch, expected, actual}}, state}
        end
    end
  end

  def handle_call(:fixture, _from, %{mode: :record} = state) do
    entries = state.entries |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    {:reply, Fixture.new(%{compatibility: state.compatibility, entries: entries}), state}
  end

  def handle_call(:fixture, _from, %{mode: :replay, fixture: fixture} = state), do: {:reply, {:ok, fixture}, state}

  def handle_call(:finish, _from, %{mode: :record} = state), do: {:reply, :ok, state}

  def handle_call(:finish, _from, %{mode: :replay} = state) do
    remaining = length(state.fixture.entries) - state.cursor

    if remaining == 0,
      do: {:reply, :ok, state},
      else: {:reply, {:error, {:capability_replay_extra_calls, state.cursor + 1, remaining}}, state}
  end

  def handle_call(:provenance, _from, %{mode: :record} = state) do
    provenance =
      case fixture_from_state(state) do
        {:ok, fixture} ->
          %{
            "mode" => "record",
            "fixture_digest" => fixture.digest,
            "recorded_evidence" => true,
            "matched_calls" => map_size(state.entries),
            "total_calls" => map_size(state.entries)
          }

        {:error, _reason} ->
          %{"mode" => "record", "fixture_digest" => nil, "recorded_evidence" => true}
      end

    {:reply, provenance, state}
  end

  def handle_call(:provenance, _from, %{mode: :replay, fixture: fixture} = state) do
    {:reply,
     %{
       "mode" => "replay",
       "fixture_digest" => fixture.digest,
       "recorded_evidence" => true,
       "live" => false,
       "matched_calls" => state.cursor,
       "total_calls" => length(fixture.entries)
     }, state}
  end

  defp record_call(controller, class, action, fingerprint, function) do
    {index, occurrence} = GenServer.call(controller, {:reserve, class, action, fingerprint})
    result = safe_call(function)

    case Codec.encode(result, options(controller)) do
      {:ok, response} ->
        entry = %Entry{
          index: index,
          class: class,
          action: action,
          fingerprint: fingerprint,
          occurrence: occurrence,
          outcome: outcome(result),
          response: response,
          evidence: %{"source" => "recorded", "live" => false}
        }

        :ok = GenServer.call(controller, {:commit, entry})
        result

      {:error, reason} ->
        {:error, {:capability_fixture_response_rejected, reason}}
    end
  end

  defp replay_call(controller, class, action, fingerprint) do
    with {:ok, response} <- GenServer.call(controller, {:replay, class, action, fingerprint}),
         {:ok, result} <- Codec.decode(response) do
      result
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_call(function) do
    function.()
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp outcome(result) when is_tuple(result) and tuple_size(result) > 0 and elem(result, 0) == :ok, do: "ok"
  defp outcome(_result), do: "error"

  defp mode(controller), do: GenServer.call(controller, :mode)
  defp options(controller), do: GenServer.call(controller, :options)

  defp fixture_from_state(state) do
    entries = state.entries |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    Fixture.new(%{compatibility: state.compatibility, entries: entries})
  end

  defp compatible(recorded, requested) when is_map(recorded) and is_map(requested) do
    if Enum.all?(requested, fn {key, value} -> Map.get(recorded, key, Map.get(recorded, to_string(key))) == value end),
      do: :ok,
      else: {:error, {:capability_fixture_incompatible, recorded, requested}}
  end

  defp compatible(_recorded, requested), do: {:error, {:invalid_replay_compatibility, requested}}

  defp recording_opts(opts), do: [redact_strings: Keyword.get(opts, :redact_strings, [])]

  defp validate_options(opts) when is_list(opts) do
    compatibility = Keyword.get(opts, :compatibility, %{})
    redactions = Keyword.get(opts, :redact_strings, [])

    cond do
      not is_map(compatibility) -> {:error, {:invalid_replay_compatibility, compatibility}}
      not is_list(redactions) -> {:error, {:invalid_replay_redactions, redactions}}
      not Enum.all?(redactions, &(is_binary(&1) and &1 != "")) -> {:error, {:invalid_replay_redactions, redactions}}
      true -> Jidoka.ExecutionEnvironment.Contract.validate_safe_map(compatibility)
    end
  end

  defp validate_options(opts), do: {:error, {:invalid_replay_options, opts}}
end
