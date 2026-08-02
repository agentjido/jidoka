defmodule JidokaExamples.WorkflowComposition.ScriptedLLM do
  @moduledoc false

  alias Jidoka.Effect

  def capability(arguments) do
    fn _intent, %Effect.Journal{} = journal, _context ->
      if operation_result_count(journal) == 0 do
        {:ok, %{type: :operation, name: "fulfill_order", arguments: arguments}}
      else
        {:ok, %{type: :final, content: "The order workflow completed successfully."}}
      end
    end
  end

  defp operation_result_count(journal) do
    Enum.count(journal.results, fn {_id, result} -> result.kind == :operation end)
  end
end
