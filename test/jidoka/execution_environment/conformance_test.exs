defmodule Jidoka.ExecutionEnvironment.ConformanceTest do
  use ExUnit.Case, async: true

  alias Jidoka.ExecutionEnvironment.Conformance

  defmodule IncompleteAdapter do
    def open(_profile, _request, _opts), do: {:error, :not_implemented}
  end

  test "reports every missing lifecycle callback" do
    assert {:error, {:missing_adapter_callbacks, missing}} = Conformance.validate(IncompleteAdapter)
    refute {:open, 3} in missing
    assert {:acquire, 2} in missing
    assert {:cleanup, 2} in missing
  end
end
