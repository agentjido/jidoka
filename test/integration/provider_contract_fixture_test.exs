defmodule Jidoka.ProviderContractFixtureTest do
  use ExUnit.Case, async: true

  alias Jidoka.Adapter.ReqLLM.{NormalizedStream, ResponseAdapter, ToolProjection}
  alias Jidoka.Agent
  alias Jidoka.Error.ExecutionError
  alias ReqLLM.StreamChunk

  @fixture_dir Path.expand("../fixtures/provider_contracts/v1", __DIR__)
  @providers ["anthropic", "google", "openai"]
  @forbidden_fixture_keys ["api-key", "api_key", "authorization", "cookie", "x-api-key"]

  @prompt %{
    operations: [
      %{
        name: "coding.read",
        description: "Read one file.",
        idempotency: :pure,
        parameters_schema: %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}},
          "required" => ["path"],
          "additionalProperties" => false
        }
      },
      %{
        name: "coding.edit",
        description: "Replace exact text in one file.",
        idempotency: :idempotent,
        parameters_schema: %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string"},
            "old_text" => %{"type" => "string"},
            "new_text" => %{"type" => "string"}
          },
          "required" => ["path", "old_text", "new_text"],
          "additionalProperties" => false
        }
      }
    ]
  }

  setup_all do
    fixtures =
      @fixture_dir
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.map(&Jason.decode!(File.read!(&1)))
      |> Map.new(&{&1["provider"], &1})

    %{fixtures: fixtures}
  end

  test "fixtures are versioned, sanitized, and data only", %{fixtures: fixtures} do
    assert fixtures |> Map.keys() |> Enum.sort() == @providers

    Enum.each(fixtures, fn {provider, fixture} ->
      assert fixture["version"] == 1
      assert fixture["provider"] == provider
      assert is_binary(fixture["model"])
      assert Map.keys(fixture) |> Enum.sort() == ["errors", "fallback", "model", "native", "provider", "version"]

      assert Map.keys(fixture["native"]) |> Enum.sort() == [
               "dependent",
               "invalid",
               "parallel",
               "single",
               "stream",
               "truncated"
             ]

      assert Map.keys(fixture["fallback"]) |> Enum.sort() == ["dependent", "parallel", "single"]
      assert Map.keys(fixture["errors"]) |> Enum.sort() == ["authentication", "rate_limit", "timeout_ms"]
      assert data_only?(fixture)

      fixture
      |> all_keys()
      |> Enum.map(&String.downcase/1)
      |> Enum.each(&refute(&1 in @forbidden_fixture_keys))

      encoded = Jason.encode!(fixture)
      refute encoded =~ ~r/(?:sk-[a-z0-9]|AIza[0-9A-Za-z_-]|Bearer\s+)/i
      assert encoded =~ ToolProjection.provider_name("coding.read")
      assert encoded =~ ToolProjection.provider_name("coding.edit")
      assert {:ok, _model} = ReqLLM.model(fixture["model"])
    end)
  end

  test "native single and parallel calls normalize to canonical operations", %{fixtures: fixtures} do
    Enum.each(fixtures, fn {_provider, fixture} ->
      single = decision!(fixture, fixture["native"]["single"])
      assert operation_pairs(single) == [{"coding.read", %{"path" => "one"}}]
      assert_native_call_ids(single)

      parallel = decision!(fixture, fixture["native"]["parallel"])

      assert operation_pairs(parallel) == [
               {"coding.read", %{"path" => "one"}},
               {"coding.read", %{"path" => "two"}}
             ]

      assert_native_call_ids(parallel)
      assert parallel.operations |> Enum.map(& &1.provider_call_id) |> Enum.uniq() |> length() == 2
    end)
  end

  test "JSON fallback single and parallel calls match native operation contracts", %{
    fixtures: fixtures
  } do
    Enum.each(fixtures, fn {_provider, fixture} ->
      assert operation_pairs(decision!(fixture, fixture["fallback"]["single"])) ==
               [{"coding.read", %{"path" => "one"}}]

      assert operation_pairs(decision!(fixture, fixture["fallback"]["parallel"])) == [
               {"coding.read", %{"path" => "one"}},
               {"coding.read", %{"path" => "two"}}
             ]
    end)
  end

  test "dependent native and fallback responses keep read-before-edit order", %{fixtures: fixtures} do
    expected = [
      {"coding.read", %{"path" => "lib/rate_limiter.ex"}},
      {
        "coding.edit",
        %{
          "path" => "lib/rate_limiter.ex",
          "old_text" => "limit: 5",
          "new_text" => "limit: 10"
        }
      }
    ]

    Enum.each(fixtures, fn {_provider, fixture} ->
      native = Enum.flat_map(fixture["native"]["dependent"], &operation_pairs(decision!(fixture, &1)))
      fallback = Enum.flat_map(fixture["fallback"]["dependent"], &operation_pairs(decision!(fixture, &1)))

      assert native == expected
      assert fallback == expected
    end)
  end

  test "provider streams emit text but defer runnable tools until final validation", %{
    fixtures: fixtures
  } do
    Enum.each(fixtures, fn {_provider, fixture} ->
      stream = fixture["native"]["stream"]
      {:ok, model} = ReqLLM.model(fixture["model"])

      chunks =
        stream["events"]
        |> Enum.flat_map(&decode_stream_event(fixture["provider"], &1, model))

      assert Enum.any?(chunks, &match?(%StreamChunk{type: :content, text: "hel"}, &1))
      assert Enum.any?(chunks, &match?(%StreamChunk{type: :tool_call}, &1))
      assert Enum.any?(chunks, &(Map.get(&1.metadata, :terminal?, false) == true))

      {state, streaming_records} =
        Enum.reduce(chunks, {NormalizedStream.new(), []}, fn chunk, {state, records} ->
          {state, emitted} = NormalizedStream.push(state, chunk)
          {state, records ++ emitted}
        end)

      assert streaming_records == [%{type: :text_delta, delta: "hel"}]
      refute Enum.any?(streaming_records, &(&1.type == :tool_call))

      {response, decision} = response_and_decision!(fixture, stream["response"])
      {_state, completion_records} = NormalizedStream.complete(state, response, decision)

      assert [%{type: :tool_call, call: call}] =
               Enum.filter(completion_records, &(&1.type == :tool_call))

      assert call.name == "coding.read"
      assert call.arguments == %{"path" => "stream.ex"}
      assert Enum.count(completion_records, &NormalizedStream.terminal?/1) == 1
      refute Enum.any?(completion_records, &(&1.type == :text_delta))
    end)
  end

  test "invalid and truncated responses produce stable errors", %{fixtures: fixtures} do
    Enum.each(fixtures, fn {_provider, fixture} ->
      {:ok, model} = ReqLLM.model(fixture["model"])
      {:ok, invalid} = ReqLLM.Response.decode_response(fixture["native"]["invalid"], model)

      assert {:error, {:unknown_provider_tool_name, "unknown_tool"}} =
               ResponseAdapter.decision(invalid, model, ReqLLM.Response.text(invalid), prompt: @prompt)

      {:ok, truncated} = ReqLLM.Response.decode_response(fixture["native"]["truncated"], model)

      assert {:error, {:llm_response_incomplete, :length}} =
               ResponseAdapter.decision(truncated, model, ReqLLM.Response.text(truncated), prompt: @prompt)
    end)
  end

  test "authentication and rate-limit responses keep their HTTP class", %{fixtures: fixtures} do
    Enum.each(fixtures, fn {_provider, fixture} ->
      Enum.each([{"authentication", 401}, {"rate_limit", 429}], fn {case_name, status} ->
        contract = fixture["errors"][case_name]

        assert %ReqLLM.Error.API.Response{status: ^status, response_body: response_body} =
                 decode_http_error(fixture, contract)

        assert response_body == contract["body"]
      end)
    end)
  end

  test "provider capability timeouts are typed and kill the slow call", %{fixtures: fixtures} do
    Enum.each(fixtures, fn {provider, fixture} ->
      parent = self()
      timeout_ms = fixture["errors"]["timeout_ms"]

      slow_llm = fn _intent, _journal, _context ->
        send(parent, {:slow_provider_started, provider, self()})
        Process.sleep(5_000)
        {:ok, %{type: :final, content: "too late"}}
      end

      assert {:error,
              %ExecutionError{
                phase: :effect,
                details: %{
                  reason: :capability_timeout,
                  effect_kind: :llm,
                  timeout_ms: ^timeout_ms
                }
              }} =
               Jidoka.turn(timeout_spec(provider), "Time out the provider fixture",
                 llm: slow_llm,
                 capability_timeout_ms: timeout_ms
               )

      assert_receive {:slow_provider_started, ^provider, capability_pid}, 1_000
      refute Process.alive?(capability_pid)
    end)
  end

  defp decision!(fixture, raw) do
    {_response, decision} = response_and_decision!(fixture, raw)
    decision
  end

  defp response_and_decision!(fixture, raw) do
    {:ok, model} = ReqLLM.model(fixture["model"])
    {:ok, response} = ReqLLM.Response.decode_response(raw, model)

    {:ok, decision} =
      ResponseAdapter.decision(response, model, ReqLLM.Response.text(response), prompt: @prompt)

    {response, decision}
  end

  defp operation_pairs(decision) do
    Enum.map(decision.operations, &{&1.name, &1.arguments})
  end

  defp assert_native_call_ids(decision) do
    assert Enum.all?(decision.operations, &(is_binary(&1.provider_call_id) and &1.provider_call_id != ""))
  end

  defp decode_stream_event("openai", event, model) do
    ReqLLM.Providers.OpenAI.decode_stream_event(
      %{event: event["event"], data: event["data"]},
      model
    )
  end

  defp decode_stream_event("anthropic", event, model) do
    ReqLLM.Providers.Anthropic.decode_stream_event(%{data: event["data"]}, model)
  end

  defp decode_stream_event("google", event, model) do
    ReqLLM.Providers.Google.decode_stream_event(event, model)
  end

  defp decode_http_error(fixture, contract) do
    {:ok, model} = ReqLLM.model(fixture["model"])
    {:ok, provider} = ReqLLM.provider(model.provider)

    request = %Req.Request{
      private: %{req_llm_model: model},
      options: %{model: model.id}
    }

    response = %Req.Response{
      status: contract["status"],
      body: contract["body"],
      headers: contract["headers"] || %{}
    }

    {_request, error} = provider.decode_response({request, response})
    error
  end

  defp timeout_spec(provider) do
    Agent.Spec.new!(
      id: "#{provider}-provider-timeout-fixture",
      instructions: "Return one final response.",
      model: %{provider: :test, id: "fixture-model"},
      operations: []
    )
  end

  defp data_only?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and data_only?(item) end)

  defp data_only?(value) when is_list(value), do: Enum.all?(value, &data_only?/1)
  defp data_only?(value) when is_binary(value) or is_number(value) or is_boolean(value), do: true
  defp data_only?(nil), do: true
  defp data_only?(_value), do: false

  defp all_keys(value) when is_map(value) do
    Enum.flat_map(value, fn {key, item} -> [key | all_keys(item)] end)
  end

  defp all_keys(value) when is_list(value), do: Enum.flat_map(value, &all_keys/1)
  defp all_keys(_value), do: []
end
