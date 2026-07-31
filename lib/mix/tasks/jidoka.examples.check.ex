defmodule Mix.Tasks.Jidoka.Examples.Check do
  @moduledoc """
  Checks the example catalog and its proof surfaces.

      mix jidoka.examples.check
      mix jidoka.examples.check --example support_agent
      mix jidoka.examples.check --changed origin/main
      mix jidoka.examples.check --verbose

  The default command checks all scenarios. It does not make network calls.
  """

  use Mix.Task

  @shortdoc "Checks all Jidoka example proof surfaces"
  @examples_dir Path.expand("../../../examples", __DIR__)
  @check_module Module.concat([JidokaExamples, Check])

  @impl Mix.Task
  def run(args) do
    ensure_root_project!()

    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          all: :boolean,
          changed: :string,
          example: :string,
          help: :boolean,
          json: :boolean,
          verbose: :boolean
        ],
        aliases: [a: :all, h: :help]
      )

    validate_args!(opts, positional, invalid)

    if opts[:help] do
      print_help()
    else
      Code.require_file(Path.join(@examples_dir, "_support/check.exs"))

      result =
        apply(@check_module, :run, [
          [
            example: opts[:example],
            changed: opts[:changed],
            verbose: opts[:verbose] || false
          ]
        ])

      print_result(result, opts)

      if result.status == :error do
        Mix.raise("Jidoka example checks failed.")
      end
    end
  end

  defp validate_args!(opts, positional, invalid) do
    if invalid != [], do: Mix.raise("Unknown options: #{inspect(invalid)}")
    if positional != [], do: Mix.raise("Unexpected arguments: #{Enum.join(positional, " ")}")
    if opts[:json] && opts[:verbose], do: Mix.raise("Use only one of --json or --verbose.")

    selections = Enum.count([opts[:all], opts[:changed], opts[:example]], &(&1 not in [nil, false]))

    if selections > 1 do
      Mix.raise("Use only one of --all, --changed, or --example.")
    end
  end

  defp print_result(result, opts) do
    if opts[:json] do
      Mix.shell().info(result |> json_safe() |> Jason.encode!(pretty: true))
    else
      Mix.shell().info("Jidoka example checks")
      Mix.shell().info("Selected: #{format_selected(result.selection.examples)}")
      print_selection_reasons(result.selection.reasons)

      Enum.each(result.gates, &print_gate/1)
      print_coverage(result.coverage)
    end
  end

  defp print_gate(gate) do
    Mix.shell().info("#{gate_marker(gate.status)}  #{gate.id} (#{gate.duration_ms} ms)")
    print_gate_message(gate)
  end

  defp print_gate_message(%{status: status, message: message, output: output}) when status != :ok do
    message
    |> String.split("\n")
    |> Enum.each(&Mix.shell().info("      #{&1}"))

    if is_binary(output) and String.trim(output) != "" do
      output
      |> String.trim()
      |> String.split("\n")
      |> Enum.each(&Mix.shell().info("      #{&1}"))
    end
  end

  defp print_gate_message(_gate), do: :ok

  defp print_coverage(coverage) when map_size(coverage) == 0, do: :ok

  defp print_coverage(coverage) do
    labels = coverage |> Map.keys() |> Enum.sort() |> Enum.join(", ")
    Mix.shell().info("Verified in this run: #{labels}")
  end

  defp print_selection_reasons([]), do: :ok

  defp print_selection_reasons(reasons) do
    Enum.each(reasons, fn reason ->
      Mix.shell().info("Reason: #{reason.subject} - #{reason.reason}")
    end)
  end

  defp gate_marker(:ok), do: "PASS"
  defp gate_marker(:error), do: "FAIL"
  defp gate_marker(:skipped), do: "SKIP"

  defp print_help do
    Mix.shell().info("""
    Check Jidoka examples:

      mix jidoka.examples.check
      mix jidoka.examples.check --example support_agent
      mix jidoka.examples.check --changed origin/main

    Options:
      --all             Check all scenarios. This is the default.
      --example NAME    Check one scenario.
      --changed REF     Check scenarios changed since a Git reference.
      --verbose         Stream complete gate output with gate prefixes.
      --json            Print a machine-readable result.
    """)
  end

  defp ensure_root_project! do
    if Mix.Project.config()[:app] != :jidoka do
      Mix.raise("Run this task from the Jidoka package root.")
    end
  end

  defp format_selected([]), do: "none"
  defp format_selected(names), do: Enum.join(names, ", ")

  defp json_safe(%_{} = struct), do: struct |> Map.from_struct() |> json_safe()
  defp json_safe(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)
  defp json_safe(values) when is_list(values), do: Enum.map(values, &json_safe/1)
  defp json_safe(value) when is_atom(value) and value in [true, false, nil], do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value
end
