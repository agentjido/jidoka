defmodule JidokaTest.HookGuardrailContractTest do
  use ExUnit.Case, async: true

  defmodule MissingContract do
  end

  defmodule BlankHook do
    def name, do: " "
    def call(input), do: {:ok, input}
  end

  defmodule BlankGuardrail do
    def name, do: " "
    def call(_input), do: :ok
  end

  test "hook contract helpers validate modules and names" do
    assert Jidoka.Hook.validate_hook_module(JidokaTest.InjectTenantHook) == :ok
    assert Jidoka.Hook.hook_name(JidokaTest.InjectTenantHook) == {:ok, "inject_tenant"}

    assert Jidoka.Hook.hook_names([JidokaTest.InjectTenantHook, JidokaTest.NormalizeReplyHook]) ==
             {:ok, ["inject_tenant", "normalize_reply"]}

    assert {:error, error} = Jidoka.Hook.validate_hook_module(MissingContract)
    assert error =~ "missing name/0, call/1"

    assert {:error, error} = Jidoka.Hook.hook_name(BlankHook)
    assert error =~ "must publish a non-empty string name"

    assert {:error, error} = Jidoka.Hook.hook_name(:bad)
    assert error =~ "could not be loaded"

    assert {:error, error} = Jidoka.Hook.hook_name(42)
    assert error =~ "entries must be modules"
  end

  test "hook registry helpers normalize and resolve names" do
    assert {:ok, registry} = Jidoka.Hook.normalize_available_hooks([JidokaTest.InjectTenantHook])
    assert registry == %{"inject_tenant" => JidokaTest.InjectTenantHook}
    assert Jidoka.Hook.normalize_available_hooks(%{"inject_tenant" => JidokaTest.InjectTenantHook}) == {:ok, registry}
    assert Jidoka.Hook.resolve_hook_names(["inject_tenant"], registry) == {:ok, [JidokaTest.InjectTenantHook]}

    assert {:error, error} = Jidoka.Hook.normalize_available_hooks(%{123 => JidokaTest.InjectTenantHook})
    assert error =~ "registry keys must be strings"

    assert {:error, error} = Jidoka.Hook.normalize_available_hooks(%{" " => JidokaTest.InjectTenantHook})
    assert error =~ "registry keys must not be empty"

    assert {:error, error} = Jidoka.Hook.normalize_available_hooks(%{"wrong" => JidokaTest.InjectTenantHook})
    assert error =~ "must match published hook name"

    assert {:error, error} = Jidoka.Hook.normalize_available_hooks(:bad)
    assert error =~ "available_hooks must be"

    assert Jidoka.Hook.resolve_hook_names(["missing"], registry) == {:error, "unknown hook \"missing\""}

    assert Jidoka.Hook.resolve_hook_names(:bad, registry) ==
             {:error, "hook names must be a list and registry must be a map"}
  end

  test "guardrail contract helpers validate modules and names" do
    assert Jidoka.Guardrail.validate_guardrail_module(JidokaTest.SafePromptGuardrail) == :ok
    assert Jidoka.Guardrail.guardrail_name(JidokaTest.SafePromptGuardrail) == {:ok, "safe_prompt"}

    assert Jidoka.Guardrail.guardrail_names([
             JidokaTest.SafePromptGuardrail,
             JidokaTest.SafeReplyGuardrail
           ]) == {:ok, ["safe_prompt", "safe_reply"]}

    assert {:error, error} = Jidoka.Guardrail.validate_guardrail_module(MissingContract)
    assert error =~ "missing name/0, call/1"

    assert {:error, error} = Jidoka.Guardrail.guardrail_name(BlankGuardrail)
    assert error =~ "must publish a non-empty string name"

    assert {:error, error} = Jidoka.Guardrail.guardrail_name(:bad)
    assert error =~ "could not be loaded"

    assert {:error, error} = Jidoka.Guardrail.guardrail_name(42)
    assert error =~ "entries must be modules"
  end

  test "guardrail registry helpers normalize and resolve names" do
    assert {:ok, registry} = Jidoka.Guardrail.normalize_available_guardrails([JidokaTest.SafePromptGuardrail])
    assert registry == %{"safe_prompt" => JidokaTest.SafePromptGuardrail}

    assert Jidoka.Guardrail.normalize_available_guardrails(%{"safe_prompt" => JidokaTest.SafePromptGuardrail}) ==
             {:ok, registry}

    assert Jidoka.Guardrail.resolve_guardrail_names(["safe_prompt"], registry) ==
             {:ok, [JidokaTest.SafePromptGuardrail]}

    assert {:error, error} =
             Jidoka.Guardrail.normalize_available_guardrails(%{123 => JidokaTest.SafePromptGuardrail})

    assert error =~ "registry keys must be strings"

    assert {:error, error} =
             Jidoka.Guardrail.normalize_available_guardrails(%{" " => JidokaTest.SafePromptGuardrail})

    assert error =~ "registry keys must not be empty"

    assert {:error, error} =
             Jidoka.Guardrail.normalize_available_guardrails(%{"wrong" => JidokaTest.SafePromptGuardrail})

    assert error =~ "must match published guardrail name"

    assert {:error, error} = Jidoka.Guardrail.normalize_available_guardrails(:bad)
    assert error =~ "available_guardrails must be"

    assert Jidoka.Guardrail.resolve_guardrail_names(["missing"], registry) == {:error, "unknown guardrail \"missing\""}

    assert Jidoka.Guardrail.resolve_guardrail_names(:bad, registry) ==
             {:error, "guardrail names must be a list and registry must be a map"}
  end
end
