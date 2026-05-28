defmodule Mix.Tasks.Jidoka.Example do
  @moduledoc """
  Runs a named Jidoka example.

      mix jidoka.example --list
      mix jidoka.example support_agent
      mix jidoka.example support_agent --live --prompt "Triage ticket T-100"
      mix jidoka.example --all

  Examples run in provider-free verification mode by default. Pass `--live` to
  make the example perform a real `Jidoka.chat/3` call. Live mode requires
  `ANTHROPIC_API_KEY` or a compatible provider environment configured by the
  example.
  """

  use Mix.Task

  @shortdoc "Runs a named Jidoka example"
  @examples_dir Path.expand("../../../examples", __DIR__)
  @registry_module Module.concat([JidokaExamples])

  @impl Mix.Task
  def run(args) do
    Code.require_file(Path.join(@examples_dir, "registry.exs"))

    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          all: :boolean,
          help: :boolean,
          json: :boolean,
          list: :boolean,
          live: :boolean,
          prompt: :string,
          provider_env: :string,
          show_logs: :boolean,
          verify: :boolean
        ],
        aliases: [a: :all, h: :help, l: :list, p: :prompt]
      )

    if invalid != [] do
      Mix.raise("Unknown jidoka.example options: #{inspect(invalid)}")
    end

    unless opts[:show_logs], do: Logger.configure(level: :error)

    cond do
      opts[:help] ->
        print_help()

      opts[:list] ->
        print_examples(opts)

      opts[:all] ->
        run_all(opts)

      positional == [] ->
        print_help()

      length(positional) == 1 ->
        run_one(List.first(positional), opts)

      true ->
        Mix.raise("Expected one example name, got: #{Enum.join(positional, " ")}")
    end
  end

  defp print_examples(opts) do
    examples =
      Enum.map(examples(), fn example ->
        %{
          name: example.name,
          title: example.title,
          features: example.features
        }
      end)

    if opts[:json] do
      Mix.shell().info(encode_json!(examples))
    else
      Mix.shell().info("Available Jidoka examples:\n")

      for example <- examples() do
        name = example.name |> Atom.to_string() |> String.pad_trailing(20)
        Mix.shell().info("  #{name} #{example.title} (#{feature_labels(example.features)})")
      end
    end
  end

  defp run_all(opts) do
    results =
      Enum.map(examples(), fn %{name: name} ->
        {name, run_example(name, example_opts(opts))}
      end)

    failures = Enum.filter(results, fn {_name, result} -> not match?({:ok, _}, result) end)

    if failures != [] do
      details =
        failures
        |> Enum.map(fn {name, {:error, reason}} -> "#{name}: #{format_error(reason)}" end)
        |> Enum.join("\n")

      Mix.raise("One or more examples failed:\n#{details}")
    end

    payload = Map.new(results, fn {name, {:ok, result}} -> {name, result} end)
    print_result(:all, payload, opts)
  end

  defp run_one(name, opts) do
    case run_example(name, example_opts(opts)) do
      {:ok, result} ->
        print_result(name, result, opts)

      {:error, reason} ->
        Mix.raise("Example #{inspect(name)} failed: #{format_error(reason)}")
    end
  end

  defp example_opts(opts) do
    []
    |> maybe_put(:live, opts[:live])
    |> maybe_put(:prompt, opts[:prompt])
    |> maybe_put(:provider_env, opts[:provider_env])
  end

  defp print_result(name, result, opts) do
    if opts[:json] do
      Mix.shell().info(encode_json!(result))
    else
      IO.inspect(result, label: "jidoka.example #{name}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, false), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp encode_json!(value) do
    value
    |> json_safe()
    |> Jason.encode!(pretty: true)
  end

  defp json_safe(%_{} = struct), do: struct |> Jidoka.Sanitize.payload() |> json_safe()

  defp json_safe(%{} = map) do
    Map.new(map, fn {key, value} -> {json_key(key), json_safe(value)} end)
  end

  defp json_safe(values) when is_list(values), do: Enum.map(values, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(value) when is_binary(value), do: Jidoka.Sanitize.text(value)
  defp json_safe(value) when is_atom(value) and value in [true, false, nil], do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_pid(value), do: inspect(value)
  defp json_safe(value) when is_function(value), do: inspect(value)
  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: inspect(key)

  defp examples, do: apply(@registry_module, :all, [])
  defp run_example(name, opts), do: apply(@registry_module, :run, [name, opts])
  defp feature_labels(features), do: apply(@registry_module, :feature_labels, [features])

  defp format_error({:missing_provider, message}), do: message
  defp format_error(reason), do: inspect(reason, pretty: true)

  defp print_help do
    Mix.shell().info("""
    Run Jidoka examples:

      mix jidoka.example --list
      mix jidoka.example support_agent
      mix jidoka.example support_agent --live
      mix jidoka.example --all

    Options:
      --list              List available examples
      --all               Run all examples in registry order
      --live              Use real provider calls instead of provider-free checks
      --prompt MESSAGE    Override the example prompt
      --provider-env NAME Read provider key from a specific env var
      --show-logs         Leave normal runtime warnings/logs visible
      --json              Print machine-readable JSON
    """)
  end
end
