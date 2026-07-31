defmodule Mix.Tasks.Jidoka.Example do
  @moduledoc """
  Lists or runs deterministic Jidoka examples.

      mix jidoka.example --list
      mix jidoka.example support_agent
      mix jidoka.example --all
  """

  use Mix.Task

  @shortdoc "Lists or runs deterministic Jidoka examples"
  @examples_dir Path.expand("../../../examples", __DIR__)
  @registry_module Module.concat([JidokaExamples])

  @impl Mix.Task
  def run(args) do
    Code.require_file(Path.join(@examples_dir, "_support/registry.exs"))

    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [all: :boolean, help: :boolean, json: :boolean, list: :boolean],
        aliases: [a: :all, h: :help, l: :list]
      )

    if invalid != [] do
      Mix.raise("Unknown jidoka.example options: #{inspect(invalid)}")
    end

    cond do
      opts[:help] -> print_help()
      opts[:list] -> print_examples(opts)
      opts[:all] -> run_all(opts)
      length(positional) == 1 -> run_one(List.first(positional), opts)
      positional == [] -> print_help()
      true -> Mix.raise("Expected one example name, got: #{Enum.join(positional, " ")}")
    end
  end

  defp print_examples(opts) do
    examples =
      Enum.map(examples(), fn example ->
        %{
          name: example.name,
          title: example.title,
          summary: example.summary,
          capabilities: capability_names(example)
        }
      end)

    if opts[:json] do
      Mix.shell().info(encode_json!(examples))
    else
      Mix.shell().info("Available Jidoka examples:\n")

      Enum.each(examples(), fn example ->
        name = example.name |> Atom.to_string() |> String.pad_trailing(20)
        capabilities = capability_labels(example)
        Mix.shell().info("  #{name} #{example.title} (#{capabilities})")
      end)
    end
  end

  defp run_all(opts) do
    results =
      Enum.map(examples(), fn example ->
        {example.name, run_example(example.name)}
      end)

    case Enum.filter(results, fn {_name, result} -> not match?({:ok, _}, result) end) do
      [] ->
        payload = Map.new(results, fn {name, {:ok, result}} -> {name, result} end)
        print_result(payload, opts)

      failures ->
        Mix.raise("One or more examples failed: #{inspect(failures, pretty: true)}")
    end
  end

  defp run_one(name, opts) do
    case run_example(name) do
      {:ok, result} -> print_result(result, opts)
      {:error, reason} -> Mix.raise("Example #{inspect(name)} failed: #{inspect(reason, pretty: true)}")
    end
  end

  defp print_result(result, opts) do
    if opts[:json] do
      Mix.shell().info(encode_json!(Jidoka.project(result)))
    else
      Mix.shell().info("jidoka.example: #{inspect(result, pretty: true)}")
    end
  end

  defp encode_json!(value), do: value |> json_safe() |> Jason.encode!(pretty: true)

  defp json_safe(%_{} = struct), do: struct |> Map.from_struct() |> json_safe()
  defp json_safe(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)
  defp json_safe(values) when is_list(values), do: Enum.map(values, &json_safe/1)
  defp json_safe(value) when is_atom(value) and value in [true, false, nil], do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp examples, do: apply(@registry_module, :all, [])
  defp run_example(name), do: apply(@registry_module, :run, [name])
  defp capability_labels(example), do: apply(@registry_module, :capability_labels, [example])

  defp capability_names(example) do
    example.scenarios
    |> Enum.flat_map(& &1.cases)
    |> Enum.flat_map(& &1.proves)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp print_help do
    Mix.shell().info("""
    Run Jidoka examples:

      mix jidoka.example --list
      mix jidoka.example support_agent
      mix jidoka.example --all

    Options:
      --list  List available examples
      --all   Run all examples
      --json  Print JSON
    """)
  end
end
