defmodule Jidoka.LiveProviderContractTest do
  use ExUnit.Case, async: false

  @moduletag :live
  @moduletag timeout: 75_000

  @enable_env "JIDOKA_LIVE_PROVIDER_CONTRACTS"
  @per_call_timeout_ms 20_000
  @suite_timeout_ms 70_000
  @max_concurrency 1
  @max_calls 3
  @max_cost_per_call 0.01
  @max_suite_cost 0.03

  @provider_cases [
    %{provider: :openai, model: "openai:gpt-4.1-mini", credential_env: "OPENAI_API_KEY"},
    %{
      provider: :anthropic,
      model: "anthropic:claude-sonnet-4-5-20250929",
      credential_env: "ANTHROPIC_API_KEY"
    },
    %{provider: :google, model: "google:gemini-2.5-flash", credential_env: "GOOGLE_API_KEY"}
  ]

  @enabled? System.get_env(@enable_env) == "1"
  @configured_cases Enum.filter(@provider_cases, &is_binary(System.get_env(&1.credential_env)))

  unless @enabled? and @configured_cases != [] do
    @moduletag :skip
  end

  test "live provider contracts stay inside strict call, cost, time, and concurrency limits" do
    {:ok, tracker} = Elixir.Agent.start_link(fn -> %{active: 0, calls: 0, max_active: 0} end)
    started_at = System.monotonic_time(:millisecond)

    results =
      @configured_cases
      |> Task.async_stream(&bounded_provider_call(&1, tracker),
        max_concurrency: @max_concurrency,
        ordered: true,
        timeout: @per_call_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    state = Elixir.Agent.get(tracker, & &1)

    assert length(results) == length(@configured_cases)
    assert state.calls == length(@configured_cases)
    assert state.calls <= @max_calls
    assert state.max_active <= @max_concurrency
    assert elapsed_ms <= @suite_timeout_ms

    costs =
      Enum.map(results, fn
        {:ok, {:ok, provider, text, cost}} ->
          assert is_binary(text) and String.trim(text) != ""
          assert is_number(cost)
          assert cost <= @max_cost_per_call
          {provider, cost}

        other ->
          flunk("bounded live provider call failed: #{inspect(other)}")
      end)

    assert Enum.map(costs, &elem(&1, 0)) == Enum.map(@configured_cases, & &1.provider)
    assert Enum.sum(Enum.map(costs, &elem(&1, 1))) <= @max_suite_cost
  end

  defp bounded_provider_call(provider_case, tracker) do
    Elixir.Agent.update(tracker, fn state ->
      active = state.active + 1
      %{state | active: active, calls: state.calls + 1, max_active: max(state.max_active, active)}
    end)

    try do
      case ReqLLM.Generation.generate_text(
             provider_case.model,
             "Reply with only OK.",
             max_tokens: 8,
             max_retries: 0,
             receive_timeout: 15_000,
             total_timeout: @per_call_timeout_ms,
             temperature: 0
           ) do
        {:ok, response} ->
          usage = ReqLLM.Response.usage(response) || %{}
          cost = Map.get(usage, :total_cost) || Map.get(usage, "total_cost")
          {:ok, provider_case.provider, ReqLLM.Response.text(response), cost}

        {:error, reason} ->
          {:error, provider_case.provider, reason}
      end
    after
      Elixir.Agent.update(tracker, &%{&1 | active: &1.active - 1})
    end
  end
end
