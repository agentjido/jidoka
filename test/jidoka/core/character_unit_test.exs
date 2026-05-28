defmodule JidokaTest.CharacterUnitTest do
  use JidokaTest.Support.Case, async: true

  alias Jidoka.Character
  alias JidokaTest.SupportCharacter

  defmodule PlainModule do
  end

  defmodule BadNewModule do
    def new, do: :bad
  end

  defmodule EmptyPromptModule do
    def new, do: {:ok, %{}}
    def to_system_prompt(_character), do: " "
  end

  defmodule InvalidPromptModule do
    def new, do: {:ok, %{}}
    def to_system_prompt(_character), do: 123
  end

  test "normalizes nil, none, maps, structs, modules, and invalid sources" do
    character = %{
      name: "Unit Advisor",
      identity: %{role: "tester"},
      voice: %{tone: :professional},
      instructions: ["Stay deterministic."]
    }

    assert Character.normalize(__MODULE__, nil) == {:ok, nil}
    assert Character.normalize(__MODULE__, :none) == {:ok, :none}

    assert {:ok, {:character, rendered}} = Character.normalize(__MODULE__, character)
    assert rendered.name == "Unit Advisor"

    assert {:ok, {:module, SupportCharacter}} = Character.normalize(__MODULE__, SupportCharacter)

    assert {:error, error} = Character.normalize(__MODULE__, PlainModule)
    assert error =~ "must be a `use Jido.Character` module"

    assert {:error, error} = Character.normalize(__MODULE__, 42)
    assert error =~ "must be a map"
  end

  test "resolves normalized, map, module, and invalid character specs" do
    assert Character.resolve(nil, %{}) == {:ok, nil}
    assert Character.resolve(:none, %{}) == {:ok, nil}

    assert {:ok, prompt} = Character.resolve(SupportCharacter, %{})
    assert prompt =~ "# Character: Support Advisor"

    assert {:ok, prompt} =
             Character.resolve(
               %{
                 name: "Runtime Advisor",
                 identity: %{role: "tester"},
                 voice: %{tone: :warm},
                 instructions: ["Use runtime persona."]
               },
               %{}
             )

    assert prompt =~ "# Character: Runtime Advisor"

    assert {:error, error} = Character.resolve({:module, BadNewModule}, %{})
    assert error =~ "new/0 returned :bad"

    assert {:error, error} = Character.resolve({:module, EmptyPromptModule}, %{})
    assert error =~ "empty prompt"

    assert {:error, error} = Character.resolve({:module, InvalidPromptModule}, %{})
    assert error =~ "rendered 123"
  end

  test "handles runtime overrides and available character registries" do
    override = {:module, SupportCharacter}

    assert Character.context_key() == :__jidoka_character__
    assert Character.runtime_override(%{Character.context_key() => override}) == override
    assert Character.runtime_override(:bad_context) == nil

    assert {:ok, registry} = Character.normalize_available_characters(support: SupportCharacter)
    assert registry == %{"support" => SupportCharacter}
    assert Character.resolve_character_name("support", registry) == {:ok, SupportCharacter}

    assert Character.normalize_available_characters(%{" " => SupportCharacter}) ==
             {:error, "character registry keys must not be empty"}

    assert Character.normalize_available_characters(%{123 => SupportCharacter}) ==
             {:error, "character registry keys must be strings or atoms"}

    assert {:error, error} = Character.normalize_available_characters(%{"bad" => PlainModule})
    assert error =~ "available character"

    assert Character.normalize_available_characters(:bad) ==
             {:error, "available_characters must be a map of character name => character source"}

    assert Character.resolve_character_name("missing", registry) == {:error, "unknown character \"missing\""}

    assert Character.resolve_character_name(:bad, registry) ==
             {:error, "character name must be a string and registry must be a map"}
  end
end
