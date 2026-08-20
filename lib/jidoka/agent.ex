defmodule Jidoka.Agent do
  @moduledoc """
  Minimal Spark DSL for defining a Jidoka agent on top of Jido.

      defmodule MyApp.TimeAgent do
        use Jidoka.Agent

        agent :time_agent do
          model "openai:gpt-4o-mini"
          instructions "Use local_time when asked for the time."
        end

        tools do
          action MyApp.Actions.LocalTime
        end
      end

      {:ok, text} = Jidoka.chat(MyApp.TimeAgent, "What time is it in Chicago?")

  Agent modules also generate bound `chat/2` and `run_turn/2` convenience
  functions. Use the root `Jidoka` facade as the main application path.
  """

  alias Jidoka.Agent.ControlCompiler
  alias Jidoka.Agent.ServerOptions
  alias Jidoka.Agent.Spec
  alias Jidoka.Agent.Spec.Generation
  alias Jidoka.Agent.Spec.Memory
  alias Jidoka.Agent.Spec.Result
  alias Jidoka.Agent.ToolSources
  alias Jidoka.Config
  alias Jidoka.Error
  alias Jidoka.Adapter.Jido.RunTurn
  alias Jidoka.Adapter.Jido.Signals
  alias Jidoka.Turn.Execution, as: TurnExecution

  @default_instructions "You are a helpful assistant."

  @doc false
  @spec default_instructions() :: String.t()
  def default_instructions, do: @default_instructions

  @doc false
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts \\ []) do
    if opts != [] do
      raise CompileError,
        file: __CALLER__.file,
        line: __CALLER__.line,
        description:
          "Jidoka.Agent now uses a Spark DSL. Use `use Jidoka.Agent` and configure it inside `agent :id do ... end`."
    end

    quote location: :keep do
      use Jidoka.Agent.SparkDsl
      @before_compile Jidoka.Agent
    end
  end

  @doc false
  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defmacro __before_compile__(env) do
    definition = compile_definition!(env.module)

    jido_opts = [
      name: definition.id,
      description: definition.description || definition.instructions,
      default_plugins: false,
      signal_routes: [{Signals.turn_run_type(), RunTurn}]
    ]

    quote location: :keep do
      use Jido.Agent, unquote(Macro.escape(jido_opts))

      @doc "Returns the compiled Jidoka DSL definition for this agent module."
      @spec __jidoka_agent__() :: map()
      def __jidoka_agent__, do: Jidoka.Agent.definition!(__MODULE__)

      @doc false
      @spec __jidoka_agent_id__() :: String.t()
      def __jidoka_agent_id__, do: unquote(definition.id)

      @doc "Returns `{action_module, opts}` action declarations for this agent."
      @spec __jidoka_tools__() :: [{module(), keyword()}]
      def __jidoka_tools__, do: Enum.map(Jidoka.Agent.action_modules(__MODULE__), &{&1, []})

      @doc "Returns the compiled `Jidoka.Agent.Spec` for this DSL agent."
      @spec spec() :: Jidoka.Agent.Spec.t()
      def spec, do: Jidoka.Agent.spec(__MODULE__)

      @doc "Runs a full turn and returns the typed `Jidoka.Turn.Result`."
      @spec run_turn(Jidoka.Turn.Request.input(), keyword()) ::
              {:ok, Jidoka.Turn.Result.t()}
              | {:hibernate, Jidoka.Snapshot.t()}
              | {:error, term()}
      def run_turn(input, opts \\ []), do: Jidoka.Agent.run_turn(__MODULE__, input, opts)

      @doc "Runs a full turn and returns only final assistant text."
      @spec chat(String.t(), keyword()) ::
              {:ok, String.t()} | {:hibernate, Jidoka.Snapshot.t()} | {:error, term()}
      def chat(input, opts \\ []), do: Jidoka.Agent.chat(__MODULE__, input, opts)

      @doc "Starts this agent under the default `Jidoka.Jido` process tree."
      @spec start(keyword()) :: DynamicSupervisor.on_start_child()
      def start(opts \\ []), do: Jidoka.Jido.start_agent(__MODULE__, opts)

      @doc "Returns a `Jido.AgentServer` child spec for supervising this agent."
      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(opts \\ []) do
        __MODULE__
        |> Jidoka.Agent.agent_server_child_opts(opts)
        |> Jido.AgentServer.child_spec()
      end
    end
  end

  @doc false
  @spec agent_server_child_opts(module(), keyword() | map()) :: keyword() | map()
  def agent_server_child_opts(agent_module, opts) when is_atom(agent_module) and is_list(opts) do
    ServerOptions.child_opts(agent_module, opts)
  end

  def agent_server_child_opts(agent_module, opts) when is_atom(agent_module) and is_map(opts) do
    ServerOptions.child_opts(agent_module, opts)
  end

  @doc """
  Returns the normalized data compiled from a Spark DSL agent module.
  """
  @spec definition!(module()) :: %{
          required(:id) => String.t(),
          required(:model) => LLMDB.Model.t(),
          required(:generation) => Generation.t(),
          required(:instructions) => String.t(),
          required(:description) => String.t() | nil,
          required(:context_schema) => term(),
          required(:result) => Result.t() | nil,
          required(:memory) => Memory.t() | nil,
          required(:actions) => [module()],
          required(:operations) => [Spec.Operation.t()],
          required(:operation_capability) => Jidoka.Operation.Capability.t(),
          required(:operation_source_digest) => String.t(),
          required(:tool_sources) => [map()],
          required(:controls) => Jidoka.Agent.Spec.Controls.t()
        }
  def definition!(agent_module) when is_atom(agent_module) do
    agent = fetch_agent!(agent_module)
    tools = ToolSources.compile!(agent_module)
    controls = controls!(agent_module)

    %{
      id: normalize_id!(agent.id),
      model: normalize_model!(agent_module, agent.model),
      generation: normalize_generation!(agent_module, agent.generation),
      instructions: normalize_instructions!(agent.instructions, tools.skill_prompt),
      description: agent.description,
      context_schema: agent.context,
      result: normalize_result!(agent_module, agent.result),
      memory: normalize_memory!(agent_module, agent.memory),
      actions: tools.actions,
      operations: tools.operations,
      operation_capability: tools.capability,
      operation_source_digest: tools.digest,
      tool_sources: tools.metadata,
      controls: controls
    }
  end

  defp compile_definition!(agent_module) when is_atom(agent_module) do
    agent = fetch_agent!(agent_module)

    unless is_nil(agent.model), do: normalize_model!(agent_module, agent.model)
    unless is_nil(agent.generation), do: normalize_generation!(agent_module, agent.generation)
    unless is_nil(agent.result), do: normalize_result!(agent_module, agent.result)
    unless is_nil(agent.memory), do: normalize_memory!(agent_module, agent.memory)
    ToolSources.validate!(agent_module)
    controls!(agent_module)

    %{
      id: normalize_id!(agent.id),
      instructions: normalize_instructions!(agent.instructions),
      description: agent.description
    }
  end

  @doc false
  @spec action_modules(module()) :: [module()]
  def action_modules(agent_module) when is_atom(agent_module) do
    ToolSources.action_modules(agent_module)
  end

  @doc false
  @spec controls!(module()) :: Jidoka.Agent.Spec.Controls.t()
  def controls!(agent_module) when is_atom(agent_module) do
    ControlCompiler.compile!(agent_module)
  end

  @doc """
  Compiles a DSL agent module into `Jidoka.Agent.Spec`.
  """
  @spec spec(module()) :: Spec.t()
  def spec(agent_module) when is_atom(agent_module) do
    agent_module
    |> definition!()
    |> spec_from_definition(agent_module)
  end

  defp spec_from_definition(definition, agent_module) do
    Spec.new!(
      id: definition.id,
      instructions: definition.instructions,
      model: definition.model,
      generation: definition.generation,
      context_schema: definition.context_schema,
      result: definition.result,
      memory: definition.memory,
      operations: definition.operations,
      controls: definition.controls,
      extensions: [],
      runtime_defaults: %{},
      metadata:
        %{
          "dsl_module" => inspect(agent_module),
          "dsl_operation_source_digest" => definition.operation_source_digest,
          "jido_agent" => true,
          "context_schema?" => not is_nil(definition.context_schema),
          "result_schema?" => not is_nil(definition.result)
        }
        |> maybe_put_tool_sources(definition.tool_sources)
    )
  end

  @doc """
  Runs a DSL agent turn through Jidoka turn execution.
  """
  @spec run_turn(module(), Jidoka.Turn.Request.input(), keyword()) ::
          {:ok, Jidoka.Turn.Result.t()}
          | {:hibernate, Jidoka.Snapshot.t()}
          | {:error, term()}
  def run_turn(agent_module, input, opts \\ []) when is_atom(agent_module) and is_list(opts) do
    definition = definition!(agent_module)
    spec = spec_from_definition(definition, agent_module)

    opts =
      opts
      |> Keyword.put_new(:operations, definition.operation_capability)
      |> Keyword.put_new(:dsl_operation_source_digest, definition.operation_source_digest)

    case TurnExecution.run(spec, input, opts) do
      {:ok, _result} = ok -> ok
      {:hibernate, _snapshot} = hibernate -> hibernate
      {:error, reason} -> {:error, Error.normalize(reason, operation: :turn, phase: :harness)}
    end
  end

  @doc """
  Runs a DSL agent turn and returns final assistant text.
  """
  @spec chat(module(), String.t(), keyword()) ::
          {:ok, String.t()} | {:hibernate, Jidoka.Snapshot.t()} | {:error, term()}
  def chat(agent_module, input, opts \\ []) when is_binary(input) and is_list(opts) do
    with {:ok, %{content: content}} <- run_turn(agent_module, input, opts) do
      {:ok, content}
    end
  end

  defp fetch_agent!(agent_module) do
    case Spark.Dsl.Extension.get_entities(agent_module, [:jidoka]) do
      [%Jidoka.Agent.Dsl.Agent{} = agent] ->
        agent

      [] ->
        raise ArgumentError, "#{inspect(agent_module)} must define `agent :id do ... end`"

      agents ->
        raise ArgumentError,
              "#{inspect(agent_module)} must define exactly one agent block, got #{length(agents)}"
    end
  end

  defp normalize_id!(id) when is_atom(id) and not is_nil(id),
    do: id |> Atom.to_string() |> normalize_id!()

  defp normalize_id!(id) when is_binary(id) do
    id = String.trim(id)

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, id) do
      id
    else
      raise ArgumentError, "agent id must be lower snake case, got: #{inspect(id)}"
    end
  end

  defp normalize_id!(id),
    do: raise(ArgumentError, "agent id must be an atom or string, got: #{inspect(id)}")

  defp normalize_model!(agent_module, nil),
    do: normalize_dsl_value!(agent_module, [:agent, :model], fn -> Config.default_model() end)

  defp normalize_model!(agent_module, model) do
    normalize_dsl_value!(agent_module, [:agent, :model], fn ->
      Config.normalize_model_spec!(model)
    end)
  end

  defp normalize_generation!(agent_module, nil),
    do:
      normalize_dsl_value!(agent_module, [:agent, :generation], fn ->
        Config.default_generation()
      end)

  defp normalize_generation!(agent_module, generation) do
    normalize_dsl_value!(agent_module, [:agent, :generation], fn ->
      Config.normalize_generation!(generation)
    end)
  end

  defp normalize_result!(_agent_module, nil), do: nil

  defp normalize_result!(agent_module, result) do
    normalize_dsl_value!(agent_module, [:agent, :result], fn ->
      Result.from_input(result)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> raise ArgumentError, "invalid agent result: #{inspect(reason)}"
      end
    end)
  end

  defp normalize_memory!(_agent_module, nil), do: nil

  defp normalize_memory!(agent_module, memory) do
    normalize_dsl_value!(agent_module, [:agent, :memory], fn ->
      Memory.from_input(memory)
      |> case do
        {:ok, memory} -> memory
        {:error, reason} -> raise ArgumentError, "invalid agent memory: #{inspect(reason)}"
      end
    end)
  end

  defp normalize_dsl_value!(agent_module, path, fun) when is_function(fun, 0) do
    fun.()
  rescue
    exception ->
      reraise Spark.Error.DslError.exception(
                message: normalize_dsl_error_message(path, exception),
                path: path,
                module: agent_module
              ),
              __STACKTRACE__
  end

  defp normalize_dsl_error_message([:agent, :model], exception) do
    "`agent.model` must be a valid ReqLLM/LLMDB model input: " <> Exception.message(exception)
  end

  defp normalize_dsl_error_message([:agent, :generation], exception) do
    "`agent.generation` must be a map or keyword list: " <> Exception.message(exception)
  end

  defp normalize_dsl_error_message([:agent, :result], exception) do
    "`agent.result` must be a Zoi schema or `Jidoka.Agent.Spec.Result` data: " <>
      Exception.message(exception)
  end

  defp normalize_dsl_error_message(_path, exception), do: Exception.message(exception)

  defp normalize_instructions!(instructions, skill_prompt \\ nil)

  defp normalize_instructions!(nil, skill_prompt),
    do: append_skill_prompt(@default_instructions, skill_prompt)

  defp normalize_instructions!(instructions, skill_prompt) when is_binary(instructions) do
    case String.trim(instructions) do
      "" -> raise ArgumentError, "agent instructions must be a non-empty string"
      instructions -> append_skill_prompt(instructions, skill_prompt)
    end
  end

  defp normalize_instructions!(instructions, _skill_prompt),
    do: raise(ArgumentError, "agent instructions must be a string, got: #{inspect(instructions)}")

  defp append_skill_prompt(instructions, nil), do: instructions
  defp append_skill_prompt(instructions, ""), do: instructions

  defp append_skill_prompt(instructions, skill_prompt) when is_binary(skill_prompt) do
    instructions <> "\n\n" <> skill_prompt
  end

  defp maybe_put_tool_sources(metadata, []), do: metadata

  defp maybe_put_tool_sources(metadata, tool_sources),
    do: Map.put(metadata, "tool_sources", tool_sources)
end
