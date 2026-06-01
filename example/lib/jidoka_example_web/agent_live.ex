defmodule JidokaExampleWeb.AgentLive do
  @moduledoc false

  def form(question, model) do
    Phoenix.Component.to_form(%{"question" => question, "model" => model}, as: :prompt)
  end

  def mount_agent(socket, params, view_module, opts)
      when is_atom(view_module) and is_list(opts) do
    session_id = Jidoka.Id.random("example_session")
    sources = Keyword.fetch!(opts, :sources)
    example_root = Keyword.fetch!(opts, :example_root)
    package_root = Keyword.get(opts, :package_root)
    default_question = Keyword.fetch!(opts, :default_question)

    Phoenix.Component.assign(socket,
      agent_view: initial_view(view_module, session_id),
      active_tab: active_tab(params, Keyword.get(opts, :tabs, ~w(activity source))),
      active_source: active_source(params, sources),
      active_request_id: nil,
      form: form(default_question, default_model()),
      guide: Keyword.fetch!(opts, :guide),
      live_ready?: live_ready(Keyword.get(opts, :credentials, :llm)),
      page_title: Keyword.fetch!(opts, :page_title),
      session_id: session_id,
      source_examples: source_examples(sources, example_root, package_root)
    )
  end

  def apply_route(socket, params, tabs, sources) do
    Phoenix.Component.assign(socket,
      active_tab: active_tab(params, tabs),
      active_source: active_source(params, sources)
    )
  end

  def run_prompt(socket, params, view_module, opts) when is_atom(view_module) and is_list(opts) do
    question = params |> Map.get("question", "") |> to_string() |> String.trim()
    model = params |> Map.get("model", "") |> to_string() |> String.trim()

    socket
    |> Phoenix.Component.assign(form: form(question, model))
    |> run_prompt_with(question, model, view_module, opts)
  end

  def default_model do
    Application.get_env(:jidoka_example, :default_model, "openai:gpt-4o-mini")
  end

  def live_llm_ready? do
    Application.get_env(:jidoka_example, :live_llm_ready?, false)
  end

  def live_research_ready? do
    Application.get_env(:jidoka_example, :live_research_ready?, false)
  end

  def initial_view(view_module, session_id) when is_atom(view_module) do
    {:ok, agent_view} = view_module.initial(%{conversation_id: session_id})
    agent_view
  end

  def source_examples(sources, example_root, package_root \\ nil) do
    Enum.map(sources, fn source ->
      source
      |> Map.put(:source, read_source(source, example_root, package_root))
      |> Map.put(:path, source.path)
    end)
  end

  def active_tab(%{"tab" => tab}, tabs) when is_binary(tab) and is_list(tabs) do
    if tab in tabs, do: tab, else: "activity"
  end

  def active_tab(_params, _tabs), do: "activity"

  def active_source(%{"source" => source}, sources) when is_binary(source) and is_list(sources) do
    if Enum.any?(sources, &(&1.id == source)), do: source, else: "agent"
  end

  def active_source(_params, _sources), do: "agent"

  def current_request?(socket, request_id) do
    is_binary(request_id) and socket.assigns[:active_request_id] == request_id
  end

  def reset_agent_process(supervisor, agent_id)
      when is_atom(supervisor) and is_binary(agent_id) do
    with :ok <- Supervisor.terminate_child(supervisor, agent_id),
         {:ok, _pid} <- Supervisor.restart_child(supervisor, agent_id) do
      :ok
    else
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def assign_reset_error(socket, reason) do
    view = %{
      socket.assigns.agent_view
      | status: :error,
        error: reason,
        error_text: Jidoka.format_error(reason)
    }

    Phoenix.Component.assign(socket, agent_view: view)
  end

  def reset_session(socket, view_module, supervisor, agent_id, default_question)
      when is_atom(view_module) and is_atom(supervisor) and is_binary(agent_id) do
    session_id = Jidoka.Id.random("example_session")

    case reset_agent_process(supervisor, agent_id) do
      :ok ->
        Phoenix.Component.assign(socket,
          agent_view: initial_view(view_module, session_id),
          active_request_id: nil,
          form: form(default_question, default_model()),
          session_id: session_id
        )

      {:error, reason} ->
        assign_reset_error(socket, reason)
    end
  end

  def show_tab(socket, tab, tabs) do
    Phoenix.Component.assign(socket, active_tab: active_tab(%{"tab" => tab}, tabs))
  end

  def show_source(socket, source, sources) do
    Phoenix.Component.assign(socket,
      active_tab: "source",
      active_source: active_source(%{"source" => source}, sources)
    )
  end

  def apply_stream_event(socket, view_module, event) when is_atom(view_module) do
    if current_request?(socket, event.request_id) do
      Phoenix.Component.assign(socket,
        agent_view: view_module.apply_event(socket.assigns.agent_view, event)
      )
    else
      socket
    end
  end

  def finish_turn(socket, view_module, request_id, result, model) when is_atom(view_module) do
    if current_request?(socket, request_id) do
      view = view_module.after_turn(socket.assigns.agent_view, result)

      Phoenix.Component.assign(socket,
        agent_view: view,
        active_request_id: nil,
        form: form("", model)
      )
    else
      socket
    end
  end

  def resume_review(socket, view_module, agent_module, decision, opts \\ [])
      when is_atom(view_module) and is_atom(agent_module) and
             decision in [:approved, :denied] and is_list(opts) do
    case pending_snapshot(socket.assigns.agent_view) do
      {:ok, snapshot} ->
        model = opts |> Keyword.get(:model, default_model()) |> to_string() |> String.trim()
        request_id = view_module.request_id()
        parent = self()
        response = review_response(snapshot, decision)

        Task.start(fn ->
          result =
            Jidoka.resume(snapshot,
              approval: response,
              llm: resume_llm(model, parent),
              operations: operation_capability(agent_module),
              stream_to: parent
            )

          send(parent, {:jidoka_turn_result, request_id, result, model})
        end)

        Phoenix.Component.assign(socket,
          agent_view: %{socket.assigns.agent_view | status: :running, error_text: nil},
          active_request_id: request_id,
          form: form("", model)
        )

      {:error, reason} ->
        assign_reset_error(socket, reason)
    end
  end

  def agent_pid(agent_id, missing_error) when is_binary(agent_id) do
    case JidokaExample.Jido.whereis(agent_id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, missing_error}
    end
  end

  def result_value(agent_view) do
    agent_view.metadata
    |> Map.get(:last_result, %{})
    |> Map.get(:value)
  end

  def payload_value(payload, path) when is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      case payload_value(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  def payload_value(%{} = payload, key) when is_atom(key) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> Map.get(payload, Atom.to_string(key))
    end
  end

  def payload_value(%{} = payload, key) when is_binary(key), do: Map.get(payload, key)
  def payload_value(_payload, _key), do: nil

  def pretty(value), do: Jason.encode!(value, pretty: true)

  def pending_review(agent_view) do
    case pending_snapshot(agent_view) do
      {:ok, snapshot} ->
        review =
          snapshot.metadata
          |> Map.get("pending_review", Map.get(snapshot.metadata, :pending_review))

        {:ok, snapshot, review}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_prompt_with(socket, "", model, _view_module, _opts) do
    Phoenix.Component.assign(socket, form: form("", model))
  end

  defp run_prompt_with(socket, question, model, view_module, opts) do
    if socket.assigns.live_ready? do
      run_live_prompt(socket, question, model, view_module, opts)
    else
      run_missing_credentials_prompt(socket, question, model, view_module, opts)
    end
  end

  defp run_live_prompt(socket, question, model, view_module, opts) do
    agent_pid = Keyword.fetch!(opts, :agent_pid)
    example = Keyword.fetch!(opts, :example)
    running = view_module.before_turn(socket.assigns.agent_view, question)
    request_id = view_module.request_id()
    parent = self()
    session_id = socket.assigns.session_id
    context = Keyword.get(opts, :context, %{})
    memory_store = Keyword.get(opts, :memory_store)
    operation_context = Keyword.get(opts, :operation_context)

    Task.start(fn ->
      result =
        with {:ok, pid} <- agent_pid.() do
          run_opts =
            [
              request_id: request_id,
              stream: true,
              stream_to: parent,
              timeout: Keyword.get(opts, :timeout, 90_000),
              llm_opts: [model: model],
              context:
                Map.merge(
                  %{
                    surface: "phoenix_live_view",
                    example: example,
                    session_id: session_id
                  },
                  context
                )
            ]
            |> maybe_put_memory_store(memory_store)
            |> maybe_put_operation_context(operation_context)

          Jidoka.run_turn(pid, question, run_opts)
        end

      send(parent, {:jidoka_turn_result, request_id, result, model})
    end)

    Phoenix.Component.assign(socket,
      agent_view: running,
      active_request_id: request_id,
      form: form("", model)
    )
  end

  defp run_missing_credentials_prompt(socket, question, model, view_module, opts) do
    error = Keyword.get(opts, :missing_error, :missing_live_llm_credentials)

    view =
      socket.assigns.agent_view
      |> view_module.before_turn(question)
      |> view_module.after_turn({:error, error})

    Phoenix.Component.assign(socket, agent_view: view, form: form(question, model))
  end

  defp read_source(%{path: path, root: :package}, _example_root, package_root)
       when is_binary(package_root) do
    read_source_path(package_root, path)
  end

  defp read_source(%{path: path}, example_root, _package_root) do
    read_source_path(example_root, path)
  end

  defp read_source_path(root, path) do
    case File.read(Path.join(root, path)) do
      {:ok, source} -> source
      {:error, reason} -> "# Unable to read #{path}: #{inspect(reason)}"
    end
  end

  defp live_ready(:llm), do: live_llm_ready?()
  defp live_ready(:research), do: live_research_ready?()
  defp live_ready(fun) when is_function(fun, 0), do: fun.()
  defp live_ready(value) when is_boolean(value), do: value

  defp pending_snapshot(%{outcome: {:hibernate, %Jidoka.Runtime.AgentSnapshot{} = snapshot}}),
    do: {:ok, snapshot}

  defp pending_snapshot(_agent_view), do: {:error, :missing_pending_review}

  defp review_response(%Jidoka.Runtime.AgentSnapshot{} = snapshot, :approved) do
    Jidoka.Review.Response.approve(snapshot.turn_state.pending_interrupt)
  end

  defp review_response(%Jidoka.Runtime.AgentSnapshot{} = snapshot, :denied) do
    Jidoka.Review.Response.deny(snapshot.turn_state.pending_interrupt, reason: :human_rejected)
  end

  defp resume_llm(model, parent) do
    Jidoka.Runtime.ReqLLM.llm(model: model, stream: true, stream_to: parent)
  end

  defp operation_capability(agent_module) do
    spec = agent_module.spec()

    Jidoka.Agent.ToolSources.operation_capability(agent_module,
      context: %{
        agent_module: agent_module,
        jido_agent: agent_module.new(),
        jidoka_spec: spec
      }
    )
  end

  defp maybe_put_memory_store(opts, nil), do: opts

  defp maybe_put_memory_store(opts, memory_store),
    do: Keyword.put(opts, :memory_store, memory_store)

  defp maybe_put_operation_context(opts, nil), do: opts

  defp maybe_put_operation_context(opts, operation_context),
    do: Keyword.put(opts, :operation_context, operation_context)
end
