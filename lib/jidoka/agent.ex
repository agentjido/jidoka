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

      {:ok, text} = MyApp.TimeAgent.chat("What time is it in Chicago?")
  """

  alias Jidoka.Agent.Spec
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Agent.Spec.Generation
  alias Jidoka.Agent.Spec.Memory
  alias Jidoka.Agent.Spec.Result
  alias Jidoka.Config
  alias Jidoka.Runtime.Actions.RunTurn
  alias Jidoka.Runtime.JidoActions
  alias Jidoka.Runtime.ReqLLM
  alias Jidoka.Runtime.Signals

  @default_instructions "You are a helpful assistant."

  @doc false
  @spec default_instructions() :: String.t()
  def default_instructions, do: @default_instructions

  @doc false
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
      def __jidoka_agent__, do: Jidoka.Agent.definition!(__MODULE__)

      @doc "Returns `{action_module, opts}` action declarations for this agent."
      def __jidoka_tools__, do: Enum.map(Jidoka.Agent.action_modules(__MODULE__), &{&1, []})

      @doc "Returns the compiled `Jidoka.Agent.Spec` for this DSL agent."
      def spec, do: Jidoka.Agent.spec(__MODULE__)

      @doc "Runs a full turn and returns the typed `Jidoka.Turn.Result`."
      def run_turn(input, opts \\ []), do: Jidoka.Agent.run_turn(__MODULE__, input, opts)

      @doc "Runs a full turn and returns only final assistant text."
      def chat(input, opts \\ []), do: Jidoka.Agent.chat(__MODULE__, input, opts)

      @doc "Starts this agent under the default `Jidoka.Jido` process tree."
      def start(opts \\ []), do: Jidoka.start_agent(__MODULE__, opts)
    end
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
          required(:controls) => Controls.t()
        }
  def definition!(agent_module) when is_atom(agent_module) do
    agent = fetch_agent!(agent_module)
    actions = action_modules(agent_module)
    controls = controls!(agent_module)
    validate_action_modules!(agent_module, actions)

    %{
      id: normalize_id!(agent.id),
      model: normalize_model!(agent_module, agent.model),
      generation: normalize_generation!(agent_module, agent.generation),
      instructions: normalize_instructions!(agent.instructions),
      description: agent.description,
      context_schema: agent.context,
      result: normalize_result!(agent_module, agent.result),
      memory: normalize_memory!(agent_module, agent.memory),
      actions: actions,
      controls: controls
    }
  end

  defp compile_definition!(agent_module) when is_atom(agent_module) do
    agent = fetch_agent!(agent_module)
    actions = action_modules(agent_module)

    unless is_nil(agent.model), do: normalize_model!(agent_module, agent.model)
    unless is_nil(agent.generation), do: normalize_generation!(agent_module, agent.generation)
    unless is_nil(agent.result), do: normalize_result!(agent_module, agent.result)
    unless is_nil(agent.memory), do: normalize_memory!(agent_module, agent.memory)
    validate_action_modules!(agent_module, actions)
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
    agent_module
    |> Spark.Dsl.Extension.get_entities([:tools])
    |> Enum.map(fn %Jidoka.Agent.Dsl.Tool{module: action} -> action end)
  end

  @doc false
  @spec controls!(module()) :: Controls.t()
  def controls!(agent_module) when is_atom(agent_module) do
    entities = Spark.Dsl.Extension.get_entities(agent_module, [:controls])

    operations =
      entities
      |> Enum.flat_map(fn
        %Jidoka.Agent.Dsl.OperationControl{} = control ->
          [
            normalize_dsl_value!(agent_module, [:controls, :operation], fn ->
              Controls.Operation.new!(
                control: control.control,
                match: control.match
              )
            end)
          ]

        _entity ->
          []
      end)

    inputs =
      entities
      |> Enum.flat_map(fn
        %Jidoka.Agent.Dsl.InputControl{} = input ->
          [
            normalize_dsl_value!(agent_module, [:controls, :input], fn ->
              Controls.Input.new!(
                control: input.control,
                metadata: input.metadata || %{}
              )
            end)
          ]

        _entity ->
          []
      end)

    outputs =
      entities
      |> Enum.flat_map(fn
        %Jidoka.Agent.Dsl.OutputControl{} = output ->
          [
            normalize_dsl_value!(agent_module, [:controls, :output], fn ->
              Controls.Output.new!(
                control: output.control,
                metadata: output.metadata || %{}
              )
            end)
          ]

        _entity ->
          []
      end)

    normalize_dsl_value!(agent_module, [:controls], fn ->
      Controls.new!(
        max_turns: singleton_control_value(entities, Jidoka.Agent.Dsl.MaxTurnsControl),
        timeout_ms: singleton_control_value(entities, Jidoka.Agent.Dsl.TimeoutControl),
        inputs: inputs,
        operations: operations,
        outputs: outputs
      )
    end)
  end

  defp singleton_control_value(entities, entity_module) do
    entities
    |> Enum.filter(&match?(%{__struct__: ^entity_module}, &1))
    |> case do
      [] -> nil
      [%{value: value}] -> value
    end
  end

  @doc """
  Compiles a DSL agent module into `Jidoka.Agent.Spec`.
  """
  @spec spec(module()) :: Spec.t()
  def spec(agent_module) when is_atom(agent_module) do
    definition = definition!(agent_module)

    Spec.new!(
      id: definition.id,
      instructions: definition.instructions,
      model: definition.model,
      generation: definition.generation,
      context_schema: definition.context_schema,
      result: definition.result,
      memory: definition.memory,
      operations: JidoActions.operations_from_actions(definition.actions),
      controls: definition.controls,
      runtime_defaults: %{},
      metadata: %{
        "dsl_module" => inspect(agent_module),
        "jido_agent" => true,
        "context_schema?" => not is_nil(definition.context_schema),
        "result_schema?" => not is_nil(definition.result)
      }
    )
  end

  @doc """
  Runs a DSL agent turn through Jidoka's harness.
  """
  @spec run_turn(module(), Jidoka.request_input(), keyword()) :: Jidoka.run_result()
  def run_turn(agent_module, input, opts \\ []) when is_atom(agent_module) and is_list(opts) do
    spec = spec(agent_module)
    Jidoka.run_turn(spec, input, runtime_opts(agent_module, spec, opts))
  end

  @doc """
  Runs a DSL agent turn and returns final assistant text.
  """
  @spec chat(module(), String.t(), keyword()) ::
          {:ok, String.t()} | {:hibernate, Jidoka.Runtime.AgentSnapshot.t()} | {:error, term()}
  def chat(agent_module, input, opts \\ []) when is_binary(input) and is_list(opts) do
    with {:ok, %{content: content}} <- run_turn(agent_module, input, opts) do
      {:ok, content}
    end
  end

  defp runtime_opts(agent_module, %Spec{} = spec, opts) do
    actions = action_modules(agent_module)

    opts
    |> Keyword.put_new(
      :operations,
      JidoActions.operations(actions, context: operation_context(agent_module, spec, opts))
    )
    |> Keyword.put_new(:llm, ReqLLM.llm(default_llm_opts(spec, opts)))
  end

  defp operation_context(agent_module, %Spec{} = spec, opts) do
    base = %{
      agent_module: agent_module,
      jido_agent: agent_module.new(),
      jidoka_spec: spec
    }

    Map.merge(base, Keyword.get(opts, :operation_context, %{}))
  end

  defp default_llm_opts(%Spec{} = spec, opts) do
    spec.generation
    |> Generation.to_req_llm_opts()
    |> Keyword.merge(Keyword.get(opts, :llm_opts, []))
    |> Keyword.put_new(:model, spec.model)
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
      raise Spark.Error.DslError.exception(
              message: normalize_dsl_error_message(path, exception),
              path: path,
              module: agent_module
            )
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

  defp normalize_instructions!(nil), do: @default_instructions

  defp normalize_instructions!(instructions) when is_binary(instructions) do
    case String.trim(instructions) do
      "" -> raise ArgumentError, "agent instructions must be a non-empty string"
      instructions -> instructions
    end
  end

  defp normalize_instructions!(instructions),
    do: raise(ArgumentError, "agent instructions must be a string, got: #{inspect(instructions)}")

  defp validate_action_modules!(agent_module, actions) do
    action_names =
      Enum.map(actions, fn action ->
        {action, action_tool_name!(agent_module, action)}
      end)

    duplicates =
      action_names
      |> Enum.map(fn {_action, name} -> name end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> name end)

    case duplicates do
      [] ->
        :ok

      [name | _rest] ->
        raise Spark.Error.DslError.exception(
                message: "tool #{inspect(name)} is defined more than once",
                path: [:tools, :action],
                module: agent_module
              )
    end
  end

  defp action_tool_name!(agent_module, action) do
    with {:module, _module} <- Code.ensure_compiled(action),
         true <- function_exported?(action, :to_tool, 0) do
      action.to_tool().name
    else
      {:error, reason} ->
        raise Spark.Error.DslError.exception(
                message: "could not compile action #{inspect(action)}: #{inspect(reason)}",
                path: [:tools, :action],
                module: agent_module
              )

      false ->
        raise Spark.Error.DslError.exception(
                message: "#{inspect(action)} must expose `to_tool/0`",
                path: [:tools, :action],
                module: agent_module
              )
    end
  rescue
    error in [Spark.Error.DslError] ->
      reraise error, __STACKTRACE__

    error ->
      raise Spark.Error.DslError.exception(
              message: Exception.message(error),
              path: [:tools, :action],
              module: agent_module
            )
  end
end
