Code.require_file("registry.exs", __DIR__)

defmodule JidokaExamples.RegistryTest do
  use ExUnit.Case, async: true

  @examples_root __DIR__

  test "scenario names and modules are unique" do
    examples = JidokaExamples.all()

    assert examples != []
    assert Enum.uniq_by(examples, & &1.name) == examples
    assert Enum.uniq_by(examples, & &1.module) == examples
  end

  test "each manifest points to its code and proof files" do
    Enum.each(JidokaExamples.all(), fn example ->
      scenario_root = Path.join(@examples_root, example.dir)

      assert File.dir?(Path.join(scenario_root, "lib"))
      assert File.regular?(Path.join(scenario_root, example.test))
      assert File.regular?(Path.join(scenario_root, example.livebook))

      Enum.each(example.files, fn file ->
        assert File.regular?(Path.join(scenario_root, file))
      end)
    end)
  end
end
