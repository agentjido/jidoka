defmodule Jidoka.ImportedAgent.Codec do
  @moduledoc false

  alias Jidoka.ImportedAgent.Spec

  @spec decode(binary(), :auto | :json | :yaml | term()) :: {:ok, map()} | {:error, String.t()}
  def decode(source, :auto) when is_binary(source) do
    source
    |> detect_source_format()
    |> then(&decode(source, &1))
  end

  def decode(source, :json) when is_binary(source) do
    case Jason.decode(source) do
      {:ok, %{} = attrs} ->
        {:ok, attrs}

      {:ok, other} ->
        {:error, "imported Jidoka agent specs must decode to an object, got: #{inspect(other)}"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  def decode(source, :yaml) when is_binary(source) do
    case YamlElixir.read_from_string(source) do
      {:ok, %{} = attrs} ->
        {:ok, attrs}

      {:ok, other} ->
        {:error, "imported Jidoka agent specs must decode to a map, got: #{inspect(other)}"}

      {:error, error} ->
        {:error, format_error(error)}
    end
  end

  def decode(_source, format),
    do: {:error, "unsupported format #{inspect(format)}; expected :json, :yaml, or :auto"}

  @spec detect_file_format(Path.t(), :json | :yaml | nil | term()) ::
          {:ok, :json | :yaml} | {:error, String.t()}
  def detect_file_format(_path, format) when format in [:json, :yaml], do: {:ok, format}

  def detect_file_format(path, nil) when is_binary(path) do
    case Path.extname(path) do
      ".json" ->
        {:ok, :json}

      ".yaml" ->
        {:ok, :yaml}

      ".yml" ->
        {:ok, :yaml}

      ext ->
        {:error, "unsupported agent spec extension #{inspect(ext)}; expected .json, .yaml, or .yml"}
    end
  end

  def detect_file_format(_path, other),
    do: {:error, "unsupported format #{inspect(other)}; expected :json or :yaml"}

  @spec expand_skill_paths(map(), Path.t()) :: map()
  def expand_skill_paths(%{} = attrs, base_dir) when is_binary(base_dir) do
    capabilities = Map.get(attrs, "capabilities", Map.get(attrs, :capabilities, %{}))
    skill_paths = Map.get(capabilities, "skill_paths", Map.get(capabilities, :skill_paths, []))

    expanded_paths =
      Enum.map(skill_paths, fn
        path when is_binary(path) -> Path.expand(path, base_dir)
        other -> other
      end)

    expanded_capabilities =
      capabilities
      |> maybe_put("skill_paths", expanded_paths)
      |> maybe_put(:skill_paths, expanded_paths)

    attrs
    |> maybe_put("capabilities", expanded_capabilities)
    |> maybe_put(:capabilities, expanded_capabilities)
  end

  @spec encode(Spec.t(), keyword()) :: {:ok, binary()} | {:error, String.t()}
  def encode(%Spec{} = spec, opts \\ []) do
    case Keyword.get(opts, :format, :json) do
      :json ->
        {:ok, Jason.encode!(Spec.to_external_map(spec), pretty: true)}

      :yaml ->
        {:ok, encode_yaml(spec)}

      other ->
        {:error, "unsupported format #{inspect(other)}; expected :json or :yaml"}
    end
  end

  @spec format_error(term()) :: String.t()
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(%{message: message}) when is_binary(message), do: message
  def format_error(reason), do: inspect(reason)

  defp detect_source_format(source) do
    case String.trim_leading(source) do
      <<"{"::utf8, _::binary>> -> :json
      _ -> :yaml
    end
  end

  defp maybe_put(map, key, value) do
    if Map.has_key?(map, key), do: Map.put(map, key, value), else: map
  end

  defp encode_yaml(%Spec{} = spec) do
    instructions_block =
      spec.instructions
      |> String.split("\n", trim: false)
      |> Enum.map_join("\n", &"    #{&1}")

    [
      "agent:",
      "  id: #{Jason.encode!(spec.id)}",
      maybe_yaml_agent_description(spec.description),
      "  context:",
      indent_lines(encode_yaml_context(spec.context), 2),
      "defaults:",
      encode_yaml_model(spec.model),
      encode_yaml_character(spec.character),
      "  instructions: |-",
      instructions_block,
      "capabilities:",
      "  tools:",
      indent_lines(encode_yaml_tools(spec.tools), 2),
      "  skills:",
      indent_lines(encode_yaml_skills(spec.skills), 2),
      "  skill_paths:",
      indent_lines(encode_yaml_skill_paths(spec.skill_paths), 2),
      "  mcp_tools:",
      indent_lines(encode_yaml_mcp_tools(spec.mcp_tools), 2),
      "  subagents:",
      indent_lines(encode_yaml_subagents(spec.subagents), 2),
      "  workflows:",
      indent_lines(encode_yaml_workflows(spec.workflows), 2),
      "  handoffs:",
      indent_lines(encode_yaml_handoffs(spec.handoffs), 2),
      "  web:",
      indent_lines(encode_yaml_web(spec.web), 2),
      "  plugins:",
      indent_lines(encode_yaml_plugins(spec.plugins), 2),
      "lifecycle:",
      "  compaction:",
      indent_lines(encode_yaml_compaction(spec.compaction), 2),
      "  memory:",
      indent_lines(encode_yaml_memory(spec.memory), 2),
      "  hooks:",
      indent_lines(encode_yaml_hooks(spec.hooks), 2),
      "  guardrails:",
      indent_lines(encode_yaml_guardrails(spec.guardrails), 2),
      encode_yaml_output(spec.output)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp encode_yaml_model(model) when is_atom(model) do
    "  model: #{Jason.encode!(Atom.to_string(model))}"
  end

  defp encode_yaml_model(model) when is_binary(model) do
    "  model: #{Jason.encode!(model)}"
  end

  defp encode_yaml_model(%{} = model) do
    lines =
      model
      |> Enum.map(fn {key, value} -> "    #{key}: #{Jason.encode!(value)}" end)

    Enum.join(["  model:" | lines], "\n")
  end

  defp encode_yaml_character(nil), do: nil

  defp encode_yaml_character(character) when is_binary(character) do
    "  character: #{Jason.encode!(character)}"
  end

  defp encode_yaml_character(%{} = character) do
    rendered =
      character
      |> Ymlr.document!()
      |> yaml_document_body()

    "  character:\n" <> indent_lines(rendered, 4)
  end

  defp encode_yaml_output(nil), do: nil

  defp encode_yaml_output(%Jidoka.Output{} = output) do
    %{
      "output" => %{
        "schema" => output.schema,
        "retries" => output.retries,
        "on_validation_error" => Atom.to_string(output.on_validation_error)
      }
    }
    |> Ymlr.document!()
    |> yaml_document_body()
  end

  defp encode_yaml_output(%{} = output) do
    %{"output" => output}
    |> Ymlr.document!()
    |> yaml_document_body()
  end

  defp maybe_yaml_agent_description(nil), do: nil
  defp maybe_yaml_agent_description(description), do: "  description: #{Jason.encode!(description)}"

  defp indent_lines(text, spaces) when is_binary(text) and is_integer(spaces) do
    prefix = String.duplicate(" ", spaces)

    text
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", &(prefix <> &1))
  end

  defp encode_yaml_tools([]), do: "  []"
  defp encode_yaml_tools(tools), do: Enum.map_join(tools, "\n", &"  - #{Jason.encode!(&1)}")

  defp encode_yaml_skills([]), do: "  []"
  defp encode_yaml_skills(skills), do: Enum.map_join(skills, "\n", &"  - #{Jason.encode!(&1)}")

  defp encode_yaml_skill_paths([]), do: "  []"

  defp encode_yaml_skill_paths(paths) do
    Enum.map_join(paths, "\n", &"  - #{Jason.encode!(&1)}")
  end

  defp encode_yaml_mcp_tools([]), do: "  []"

  defp encode_yaml_mcp_tools(entries) do
    Enum.map_join(entries, "\n", fn entry ->
      endpoint = entry["endpoint"] || entry[:endpoint]
      prefix = entry["prefix"] || entry[:prefix]

      ["  - endpoint: #{Jason.encode!(endpoint)}" | maybe_yaml_line("prefix", prefix, "    ")]
      |> Enum.join("\n")
    end)
  end

  defp encode_yaml_subagents([]), do: "  []"

  defp encode_yaml_subagents(subagents) do
    Enum.map_join(subagents, "\n", fn subagent ->
      lines =
        [
          "  - agent: #{Jason.encode!(subagent["agent"] || subagent[:agent])}"
        ] ++
          maybe_yaml_line("as", subagent["as"] || subagent[:as]) ++
          maybe_yaml_line("description", subagent["description"] || subagent[:description]) ++
          ["    target: #{Jason.encode!(subagent["target"] || subagent[:target])}"] ++
          maybe_yaml_line("timeout_ms", subagent["timeout_ms"] || subagent[:timeout_ms], "    ") ++
          maybe_yaml_line("result", subagent["result"] || subagent[:result], "    ") ++
          maybe_yaml_forward_context(subagent["forward_context"] || subagent[:forward_context]) ++
          maybe_yaml_line("peer_id", subagent["peer_id"] || subagent[:peer_id], "    ") ++
          maybe_yaml_line(
            "peer_id_context_key",
            subagent["peer_id_context_key"] || subagent[:peer_id_context_key],
            "    "
          )

      Enum.join(lines, "\n")
    end)
  end

  defp encode_yaml_workflows([]), do: "  []"

  defp encode_yaml_workflows(workflows) do
    Enum.map_join(workflows, "\n", fn
      workflow when is_binary(workflow) ->
        "  - #{Jason.encode!(workflow)}"

      workflow ->
        lines =
          [
            "  - workflow: #{Jason.encode!(workflow["workflow"] || workflow[:workflow])}"
          ] ++
            maybe_yaml_line("as", workflow["as"] || workflow[:as]) ++
            maybe_yaml_line("description", workflow["description"] || workflow[:description]) ++
            maybe_yaml_line("timeout", workflow["timeout"] || workflow[:timeout], "    ") ++
            maybe_yaml_line("result", workflow["result"] || workflow[:result], "    ") ++
            maybe_yaml_forward_context(workflow["forward_context"] || workflow[:forward_context])

        Enum.join(lines, "\n")
    end)
  end

  defp maybe_yaml_forward_context(nil), do: []
  defp maybe_yaml_forward_context("public"), do: ["    forward_context: \"public\""]
  defp maybe_yaml_forward_context("none"), do: ["    forward_context: \"none\""]

  defp maybe_yaml_forward_context(%{} = forward_context) do
    mode = forward_context["mode"] || forward_context[:mode]
    keys = forward_context["keys"] || forward_context[:keys]

    ["    forward_context:", "      mode: #{Jason.encode!(mode)}"] ++
      case keys do
        nil -> []
        keys -> ["      keys: #{Jason.encode!(keys)}"]
      end
  end

  defp maybe_yaml_forward_context(other), do: ["    forward_context: #{Jason.encode!(other)}"]

  defp encode_yaml_handoffs([]), do: "  []"

  defp encode_yaml_handoffs(handoffs) do
    Enum.map_join(handoffs, "\n", fn
      handoff when is_binary(handoff) ->
        "  - #{Jason.encode!(handoff)}"

      handoff ->
        lines =
          [
            "  - agent: #{Jason.encode!(handoff["agent"] || handoff[:agent])}"
          ] ++
            maybe_yaml_line("as", handoff["as"] || handoff[:as]) ++
            maybe_yaml_line("description", handoff["description"] || handoff[:description]) ++
            ["    target: #{Jason.encode!(handoff["target"] || handoff[:target] || "auto")}"] ++
            maybe_yaml_forward_context(handoff["forward_context"] || handoff[:forward_context]) ++
            maybe_yaml_line("peer_id", handoff["peer_id"] || handoff[:peer_id], "    ") ++
            maybe_yaml_line(
              "peer_id_context_key",
              handoff["peer_id_context_key"] || handoff[:peer_id_context_key],
              "    "
            )

        Enum.join(lines, "\n")
    end)
  end

  defp encode_yaml_context(context) when context == %{}, do: "  {}"

  defp encode_yaml_context(context) when is_map(context) do
    Enum.map_join(context, "\n", fn {key, value} ->
      "  #{yaml_key(key)}: #{Jason.encode!(value)}"
    end)
  end

  defp encode_yaml_web([]), do: "  []"

  defp encode_yaml_web(web) do
    Enum.map_join(web, "\n", fn
      mode when is_binary(mode) ->
        "  - #{Jason.encode!(mode)}"

      entry ->
        mode = entry["mode"] || entry[:mode]
        "  - mode: #{Jason.encode!(mode)}"
    end)
  end

  defp encode_yaml_plugins([]), do: "  []"
  defp encode_yaml_plugins(plugins), do: Enum.map_join(plugins, "\n", &"  - #{Jason.encode!(&1)}")

  defp encode_yaml_compaction(nil), do: "  null"

  defp encode_yaml_compaction(%{} = compaction) do
    external = Jidoka.Compaction.externalize(compaction)

    [
      "  mode: #{Jason.encode!(external["mode"])}",
      "  strategy: #{Jason.encode!(external["strategy"])}",
      "  max_messages: #{external["max_messages"]}",
      "  keep_last: #{external["keep_last"]}",
      "  max_summary_chars: #{external["max_summary_chars"]}",
      encode_yaml_compaction_prompt(external["prompt"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp encode_yaml_compaction_prompt(nil), do: nil
  defp encode_yaml_compaction_prompt(prompt), do: "  prompt: #{Jason.encode!(prompt)}"

  defp encode_yaml_memory(nil), do: "  null"

  defp encode_yaml_memory(%{namespace: :per_agent} = memory) do
    [
      "  mode: #{Jason.encode!(Atom.to_string(memory.mode))}",
      "  namespace: \"per_agent\"",
      "  capture: #{Jason.encode!(Atom.to_string(memory.capture))}",
      "  retrieve:",
      "    limit: #{memory.retrieve.limit}",
      "  inject: #{Jason.encode!(Atom.to_string(memory.inject))}"
    ]
    |> Enum.join("\n")
  end

  defp encode_yaml_memory(%{namespace: {:shared, shared_namespace}} = memory) do
    [
      "  mode: #{Jason.encode!(Atom.to_string(memory.mode))}",
      "  namespace: \"shared\"",
      "  shared_namespace: #{Jason.encode!(shared_namespace)}",
      "  capture: #{Jason.encode!(Atom.to_string(memory.capture))}",
      "  retrieve:",
      "    limit: #{memory.retrieve.limit}",
      "  inject: #{Jason.encode!(Atom.to_string(memory.inject))}"
    ]
    |> Enum.join("\n")
  end

  defp encode_yaml_memory(%{namespace: {:context, key}} = memory) do
    [
      "  mode: #{Jason.encode!(Atom.to_string(memory.mode))}",
      "  namespace: \"context\"",
      "  context_namespace_key: #{Jason.encode!(key)}",
      "  capture: #{Jason.encode!(Atom.to_string(memory.capture))}",
      "  retrieve:",
      "    limit: #{memory.retrieve.limit}",
      "  inject: #{Jason.encode!(Atom.to_string(memory.inject))}"
    ]
    |> Enum.join("\n")
  end

  defp encode_yaml_hooks(hooks) do
    Enum.map_join([:before_turn, :after_turn, :on_interrupt], "\n", fn stage ->
      hook_names = Map.get(hooks, stage, [])

      [
        "  #{stage}:",
        if(hook_names == [],
          do: "    []",
          else: Enum.map_join(hook_names, "\n", &"    - #{Jason.encode!(&1)}")
        )
      ]
      |> Enum.join("\n")
    end)
  end

  defp encode_yaml_guardrails(guardrails) do
    Enum.map_join([:input, :output, :tool], "\n", fn stage ->
      guardrail_names = Map.get(guardrails, stage, [])

      case guardrail_names do
        [] ->
          "  #{stage}: []"

        names ->
          ["  #{stage}:" | Enum.map(names, &"    - #{Jason.encode!(&1)}")]
          |> Enum.join("\n")
      end
    end)
  end

  defp yaml_key(key) when is_atom(key), do: Atom.to_string(key)
  defp yaml_key(key) when is_binary(key), do: key

  defp maybe_yaml_line(key, value, indent \\ "    ")
  defp maybe_yaml_line(_key, nil, _indent), do: []
  defp maybe_yaml_line(_key, "", _indent), do: []

  defp maybe_yaml_line(key, value, indent) do
    ["#{indent}#{key}: #{Jason.encode!(value)}"]
  end

  defp yaml_document_body(document) do
    document
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 == "---"))
    |> Enum.join("\n")
  end
end
