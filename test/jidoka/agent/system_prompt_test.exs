defmodule JidokaTest.SystemPromptTest do
  use JidokaTest.Support.Case, async: true

  alias Jidoka.Agent.SystemPrompt

  defmodule CallbackPrompt do
    @behaviour SystemPrompt

    @impl true
    def resolve_system_prompt(%{context: %{tenant: tenant}}), do: "Serve #{tenant}."
    def resolve_system_prompt(%{context: %{mode: :ok_tuple}}), do: {:ok, "Tuple prompt."}
    def resolve_system_prompt(%{context: %{mode: :error_tuple}}), do: {:error, :no_prompt}
    def resolve_system_prompt(%{context: %{mode: :empty}}), do: " "
    def resolve_system_prompt(%{context: %{mode: :invalid}}), do: :bad_prompt
    def resolve_system_prompt(%{context: %{mode: :raise}}), do: raise("callback failed")
  end

  defmodule MissingCallback do
  end

  defmodule PromptCallbacks do
    def build(%{context: context}, prefix), do: "#{prefix} #{context.tenant}."
    def empty(_input), do: {:ok, ""}
    def invalid(_input), do: {:ok, 123}
    def error(_input), do: {:error, :nope}
    def raises(_input), do: raise("mfa failed")
  end

  test "normalizes static, callback, and MFA prompt specs" do
    assert SystemPrompt.normalize(__MODULE__, "Use policy.") == {:ok, {:static, "Use policy."}}
    assert {:error, error} = SystemPrompt.normalize(__MODULE__, " ")
    assert error =~ "must not be empty"

    assert SystemPrompt.normalize(__MODULE__, CallbackPrompt) == {:ok, {:dynamic, CallbackPrompt}}

    assert {:error, error} = SystemPrompt.normalize(__MODULE__, MissingCallback)
    assert error =~ "must implement resolve_system_prompt/1"

    assert SystemPrompt.normalize(__MODULE__, {PromptCallbacks, :build, ["Serve"]}) ==
             {:ok, {:dynamic, {PromptCallbacks, :build, ["Serve"]}}}

    assert {:error, error} = SystemPrompt.normalize(__MODULE__, {PromptCallbacks, :missing, []})
    assert error =~ "must export missing/1"

    assert {:error, error} = SystemPrompt.normalize(__MODULE__, fn -> "prompt" end)
    assert error =~ "does not support anonymous functions"

    assert {:error, error} = SystemPrompt.normalize(__MODULE__, {:bad, :shape})
    assert error =~ "must be a string"
  end

  test "resolves dynamic callback prompt results and failures" do
    input = %{
      request: %{},
      state: react_state(),
      config: react_config(JidokaTest.ChatAgent.request_transformer()),
      context: %{tenant: "acme"}
    }

    assert SystemPrompt.resolve("Static prompt.", input) == {:ok, "Static prompt."}
    assert SystemPrompt.resolve(CallbackPrompt, input) == {:ok, "Serve acme."}
    assert SystemPrompt.resolve(CallbackPrompt, %{input | context: %{mode: :ok_tuple}}) == {:ok, "Tuple prompt."}
    assert SystemPrompt.resolve(CallbackPrompt, %{input | context: %{mode: :error_tuple}}) == {:error, :no_prompt}

    assert {:error, error} = SystemPrompt.resolve(CallbackPrompt, %{input | context: %{mode: :empty}})
    assert error =~ "must not resolve to an empty string"

    assert {:error, error} = SystemPrompt.resolve(CallbackPrompt, %{input | context: %{mode: :invalid}})
    assert error =~ "must return a string"

    assert {:error, error} = SystemPrompt.resolve(CallbackPrompt, %{input | context: %{mode: :raise}})
    assert error =~ "callback failed"
  end

  test "resolves MFA prompt results and failures" do
    input = %{
      request: %{},
      state: react_state(),
      config: react_config(JidokaTest.ChatAgent.request_transformer()),
      context: %{tenant: "beta"}
    }

    assert SystemPrompt.resolve({PromptCallbacks, :build, ["Serve"]}, input) == {:ok, "Serve beta."}
    assert SystemPrompt.resolve({PromptCallbacks, :error, []}, input) == {:error, :nope}

    assert {:error, error} = SystemPrompt.resolve({PromptCallbacks, :empty, []}, input)
    assert error =~ "must not resolve to an empty string"

    assert {:error, error} = SystemPrompt.resolve({PromptCallbacks, :invalid, []}, input)
    assert error =~ "must return a string"

    assert {:error, error} = SystemPrompt.resolve({PromptCallbacks, :raises, []}, input)
    assert error =~ "mfa failed"
  end

  test "transforms request messages and extracts prompts" do
    request = react_request([%{role: :user, content: "hello"}])

    assert {:ok, %{messages: messages}} =
             SystemPrompt.transform_request(
               "System prompt.",
               request,
               react_state(),
               react_config(JidokaTest.ChatAgent.request_transformer()),
               %{}
             )

    assert [%{role: :system, content: "System prompt."}, %{role: :user, content: "hello"}] = messages
    assert SystemPrompt.extract_system_prompt(messages) == "System prompt."

    replaced = SystemPrompt.put_system_prompt([%{role: "system", content: "old"}, %{role: :user, content: "hi"}], "new")

    assert [%{role: :system, content: "new"}, %{role: :user, content: "hi"}] = replaced
    assert SystemPrompt.extract_system_prompt([%{role: :user, content: "hi"}]) == nil
  end
end
