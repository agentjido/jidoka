defmodule Jidoka.ImportedAgent.Spec do
  @moduledoc false

  alias Jidoka.ImportedAgent.Spec.{Schema, Validator}

  @type model_input ::
          atom()
          | String.t()
          | %{
              required(:provider) => String.t(),
              required(:id) => String.t(),
              optional(:base_url) => String.t()
            }
  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t() | nil,
          instructions: String.t(),
          character: String.t() | map() | nil,
          model: model_input(),
          context: map(),
          output: Jidoka.Output.t() | nil,
          compaction: Jidoka.Compaction.config() | nil,
          memory: Jidoka.Memory.config() | nil,
          tools: [String.t()],
          skills: [String.t()],
          skill_paths: [String.t()],
          mcp_tools: [map()],
          subagents: [map()],
          workflows: [String.t() | map()],
          handoffs: [String.t() | map()],
          web: [String.t() | map()],
          plugins: [String.t()],
          hooks: %{
            before_turn: [String.t()],
            after_turn: [String.t()],
            on_interrupt: [String.t()]
          },
          guardrails: %{
            input: [String.t()],
            output: [String.t()],
            tool: [String.t()]
          }
        }

  @enforce_keys [:id, :instructions, :model]
  defstruct [
    :id,
    :description,
    :instructions,
    :character,
    :model,
    context: %{},
    output: nil,
    compaction: nil,
    memory: nil,
    tools: [],
    skills: [],
    skill_paths: [],
    mcp_tools: [],
    subagents: [],
    workflows: [],
    handoffs: [],
    web: [],
    plugins: [],
    hooks: %{before_turn: [], after_turn: [], on_interrupt: []},
    guardrails: %{input: [], output: [], tool: []}
  ]

  @spec schema() :: Zoi.schema()
  def schema, do: Schema.schema()

  @spec new(map() | t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = spec, opts) do
    Validator.validate_existing(spec, opts)
  end

  def new(attrs, opts) when is_map(attrs) do
    with {:ok, parsed} <- Zoi.parse(schema(), attrs),
         spec <- from_external(parsed),
         {:ok, normalized_spec} <- Validator.validate_parsed(spec, opts) do
      {:ok, normalized_spec}
    else
      {:error, [%Zoi.Error{} | _] = errors} ->
        {:error, format_zoi_errors(errors)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def new(other, _opts),
    do: {:error, "imported Jidoka agent specs must be maps, got: #{inspect(other)}"}

  @spec to_external_map(t()) :: map()
  def to_external_map(%__MODULE__{} = spec) do
    %{
      "agent" =>
        %{
          "id" => spec.id,
          "description" => spec.description,
          "context" => spec.context
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(),
      "defaults" =>
        %{
          "model" => externalize_model(spec.model),
          "instructions" => spec.instructions,
          "character" => spec.character
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(),
      "capabilities" => %{
        "tools" => spec.tools,
        "skills" => spec.skills,
        "skill_paths" => spec.skill_paths,
        "mcp_tools" => spec.mcp_tools,
        "subagents" => spec.subagents,
        "workflows" => spec.workflows,
        "handoffs" => spec.handoffs,
        "web" => spec.web,
        "plugins" => spec.plugins
      },
      "lifecycle" => %{
        "compaction" => Jidoka.Compaction.externalize(spec.compaction),
        "memory" => externalize_memory(spec.memory),
        "hooks" => spec.hooks,
        "guardrails" => spec.guardrails
      },
      "output" => externalize_output(spec.output)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> externalize_tree()
  end

  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = spec) do
    spec
    |> to_external_map()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp from_external(%{} = attrs) do
    agent = Map.fetch!(attrs, :agent)
    defaults = Map.fetch!(attrs, :defaults)
    capabilities = Map.get(attrs, :capabilities, %{})
    lifecycle = Map.get(attrs, :lifecycle, %{})

    %__MODULE__{
      id: Map.fetch!(agent, :id),
      description: Map.get(agent, :description),
      instructions: Map.fetch!(defaults, :instructions),
      character: Map.get(defaults, :character),
      model: Map.get(defaults, :model, "fast"),
      context: Map.get(agent, :context, %{}),
      output: Map.get(attrs, :output),
      compaction: Map.get(lifecycle, :compaction),
      memory: Map.get(lifecycle, :memory),
      tools: Map.get(capabilities, :tools, []),
      skills: Map.get(capabilities, :skills, []),
      skill_paths: Map.get(capabilities, :skill_paths, []),
      mcp_tools: Map.get(capabilities, :mcp_tools, []),
      subagents: Map.get(capabilities, :subagents, []),
      workflows: normalize_workflow_specs(Map.get(capabilities, :workflows, [])),
      handoffs: normalize_handoff_specs(Map.get(capabilities, :handoffs, [])),
      web: Jidoka.Web.normalize_imported_specs(Map.get(capabilities, :web, [])),
      plugins: Map.get(capabilities, :plugins, []),
      hooks: Map.get(lifecycle, :hooks, %{before_turn: [], after_turn: [], on_interrupt: []}),
      guardrails: Map.get(lifecycle, :guardrails, %{input: [], output: [], tool: []})
    }
  end

  defp externalize_model(model) when is_atom(model), do: Atom.to_string(model)
  defp externalize_model(model), do: model

  defp externalize_tree(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {externalize_key(key), externalize_tree(value)} end)
    |> Map.new()
  end

  defp externalize_tree(values) when is_list(values), do: Enum.map(values, &externalize_tree/1)
  defp externalize_tree(value) when is_boolean(value) or is_nil(value), do: value
  defp externalize_tree(value) when is_atom(value), do: Atom.to_string(value)
  defp externalize_tree(value), do: value

  defp externalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp externalize_key(key), do: key

  defp externalize_output(nil), do: nil

  defp externalize_output(%Jidoka.Output{} = output) do
    %{
      "schema" => output.schema,
      "retries" => output.retries,
      "on_validation_error" => Atom.to_string(output.on_validation_error)
    }
  end

  defp externalize_output(%{} = output), do: output

  defp externalize_memory(nil), do: nil

  defp externalize_memory(%{namespace: :per_agent} = memory) do
    %{
      "mode" => Atom.to_string(memory.mode),
      "namespace" => "per_agent",
      "capture" => Atom.to_string(memory.capture),
      "retrieve" => %{"limit" => memory.retrieve.limit},
      "inject" => Atom.to_string(memory.inject)
    }
  end

  defp externalize_memory(%{namespace: {:shared, shared_namespace}} = memory) do
    %{
      "mode" => Atom.to_string(memory.mode),
      "namespace" => "shared",
      "shared_namespace" => shared_namespace,
      "capture" => Atom.to_string(memory.capture),
      "retrieve" => %{"limit" => memory.retrieve.limit},
      "inject" => Atom.to_string(memory.inject)
    }
  end

  defp externalize_memory(%{namespace: {:context, key}} = memory) do
    %{
      "mode" => Atom.to_string(memory.mode),
      "namespace" => "context",
      "context_namespace_key" => key,
      "capture" => Atom.to_string(memory.capture),
      "retrieve" => %{"limit" => memory.retrieve.limit},
      "inject" => Atom.to_string(memory.inject)
    }
  end

  defp normalize_workflow_specs(workflows) when is_list(workflows) do
    Enum.map(workflows, fn
      workflow when is_binary(workflow) -> %{workflow: workflow}
      %{} = workflow -> workflow
    end)
  end

  defp normalize_handoff_specs(handoffs) when is_list(handoffs) do
    Enum.map(handoffs, fn
      handoff when is_binary(handoff) -> %{agent: handoff}
      %{} = handoff -> handoff
    end)
  end

  defp format_zoi_errors(errors) do
    errors
    |> Zoi.treefy_errors()
    |> inspect(pretty: true)
  end
end
