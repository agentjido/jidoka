defmodule Jidoka.Hardening.EvaluationFixtures do
  @moduledoc "Loads and normalizes MVP evaluation fixtures from repository files."

  @fixture_path Path.join(
                  Path.expand("../../..", __DIR__),
                  "priv/fixtures/mvp_012_fixtures.exs"
                )
  @external_resource @fixture_path
  @fixtures @fixture_path |> Code.eval_file() |> elem(0)

  @spec load!() :: [map()]
  def load! do
    normalize_fixtures(@fixtures)
  end

  defp normalize_fixtures(fixtures) when is_list(fixtures) do
    fixtures
    |> Enum.map(&normalize_fixture/1)
    |> Enum.filter(&is_map/1)
  end

  defp normalize_fixture(fixture) when is_map(fixture) do
    fixture
    |> Map.put_new(
      :id,
      "generated-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    )
    |> ensure_steps()
  end

  defp normalize_fixture(_), do: nil

  defp ensure_steps(fixture) do
    steps = Map.get(fixture, :steps, [])
    Map.put(fixture, :steps, normalize_steps(steps))
  end

  defp normalize_steps(steps) when is_list(steps), do: Enum.map(steps, &normalize_step/1)
  defp normalize_steps(_), do: []

  defp normalize_step(:approve), do: :approve
  defp normalize_step(:resume), do: :resume
  defp normalize_step({:retry, opts}) when is_list(opts), do: {:retry, normalize_retry_opts(opts)}
  defp normalize_step(step), do: step

  defp normalize_retry_opts(opts) when is_list(opts), do: Enum.into(opts, %{})
end
