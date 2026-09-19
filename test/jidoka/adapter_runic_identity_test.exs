defmodule Jidoka.Adapter.Runic.IdentityTest do
  use ExUnit.Case, async: true

  alias Jidoka.Adapter.Runic.Identity, as: AdapterIdentity
  alias Jidoka.Workflow.Loop.Result

  test "runtime-only values have a stable identity projection" do
    projected =
      AdapterIdentity.project(%{
        function: fn -> :ok end,
        pid: self(),
        nested: [make_ref()]
      })

    assert projected == %{
             function: :jidoka_runtime_value,
             pid: :jidoka_runtime_value,
             nested: [:jidoka_runtime_value]
           }
  end

  test "loop results support Runic content identities" do
    result = %Result{
      value: %{status: :complete, runtime: self()},
      iterations: [],
      created_work: []
    }

    assert %Runic.Identity{domain: :fact_content} =
             Runic.Identity.project(:fact_content, result)
  end
end
