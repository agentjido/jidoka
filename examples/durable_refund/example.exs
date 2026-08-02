files = Path.wildcard(Path.join(__DIR__, "lib/**/*.ex"))
{agent_files, support_files} = Enum.split_with(files, &(Path.basename(&1) == "agent.ex"))
{scenario_files, support_files} = Enum.split_with(support_files, &(Path.basename(&1) == "scenario.ex"))

Enum.each([support_files, agent_files, scenario_files], fn group ->
  {:ok, _modules, _diagnostics} = Kernel.ParallelCompiler.require(group, return_diagnostics: true)
end)

case JidokaExamples.DurableRefund.Scenario.run([]) do
  {:ok, result} -> IO.inspect(result, pretty: true)
  {:error, reason} -> raise "Durable Refund example failed: #{inspect(reason)}"
end
