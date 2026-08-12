defmodule Jidoka.CodingPack do
  @moduledoc "Removable first-party coding-pack registration and host factory."

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.CodingPack.{Error, Instructions, Workspace}
  alias Jidoka.Extension.{Binding, Registration, Request}

  @pack_id "jido.coding_pack"
  @tool_ids [
    "coding.read",
    "coding.search",
    "coding.write",
    "coding.edit",
    "coding.shell",
    "coding.git_status",
    "coding.git_diff",
    "coding.verify"
  ]

  @type tool_entry :: %{operation: Operation.t(), handler: function()}

  @doc "Returns the stable built-in extension ID."
  @spec id() :: String.t()
  def id, do: @pack_id

  @doc "Returns all reserved first-party coding tool IDs."
  @spec tool_ids() :: [String.t()]
  def tool_ids, do: @tool_ids

  @doc "Returns the inert request used when a trusted host enables the pack."
  @spec request(map()) :: Request.t()
  def request(config \\ %{}) when is_map(config), do: Request.new!(id: @pack_id, config: config)

  @doc "Returns the portable built-in coding-pack registration."
  @spec registration() :: Registration.t()
  def registration do
    Registration.new!(%{
      identity: %{
        id: @pack_id,
        source_type: :built_in,
        source_ref: "builtin:jido-coding-pack",
        release: "1",
        content_hash: digest(Enum.join([@pack_id | @tool_ids], "\n")),
        trust: :trusted
      },
      permissions: ["context", "execution_environment", "results", "state", "tools", "ui_data"],
      capabilities: ["jido.coding_pack.workspace" | @tool_ids],
      modes: [:interactive, :automation],
      config_schema_id: "jido.coding_pack.config"
    })
  end

  @doc "Builds one trusted extension registry entry for a workspace."
  @spec entry(Workspace.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def entry(%Workspace{} = workspace, opts \\ []) do
    defaults = Keyword.get(opts, :tools, %{})
    replacements = Keyword.get(opts, :replace_tools, %{})
    disabled = Keyword.get(opts, :disable_tools, [])

    with {:ok, tools} <- compose_tools(defaults, replacements, disabled) do
      factory = fn binding, config, context -> open(binding, config, context, workspace, tools) end

      {:ok,
       %{
         registration: registration(),
         validate_config: &validate_request_config/1,
         factory: factory
       }}
    end
  end

  @doc "Composes default, replacement, and disabled tool entries with collision checks."
  @spec compose_tools(map() | list(), map() | list(), [String.t()]) ::
          {:ok, %{operations: [Operation.t()], handlers: map()}} | {:error, Error.t()}
  def compose_tools(defaults, replacements \\ %{}, disabled \\ []) do
    with {:ok, defaults} <- normalize_entries(defaults),
         {:ok, replacements} <- normalize_entries(replacements),
         :ok <- known_tool_ids(Map.keys(defaults) ++ Map.keys(replacements) ++ disabled),
         true <- is_list(disabled) and Enum.all?(disabled, &is_binary/1),
         entries = defaults |> Map.merge(replacements) |> Map.drop(disabled),
         :ok <- validate_entries(entries) do
      ordered = Enum.sort_by(entries, &elem(&1, 0))

      {:ok,
       %{
         operations: Enum.map(ordered, fn {_id, entry} -> entry.operation end),
         handlers: Map.new(ordered, fn {id, entry} -> {id, entry.handler} end)
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      false -> {:error, Error.new(:coding_tool_disable_invalid)}
    end
  end

  defp open(%Binding{} = binding, config, _context, workspace, tools) do
    with true <- binding.identity.id == @pack_id,
         :ok <- validate_request_config(config) do
      context = fn _instance, turn_context -> coding_context(workspace, turn_context) end

      {:ok, workspace,
       %{
         namespace: binding.instance_key,
         tools: tools.operations,
         tool_handlers: tools.handlers,
         context: context,
         state: %{},
         result: %{"workspace" => Workspace.to_map(workspace)},
         ui_data: %{}
       }}
    else
      reason -> {:error, Error.new(:coding_pack_open_failed, %{reason: inspect(reason)})}
    end
  end

  defp coding_context(workspace, turn_context) do
    directory =
      Map.get(turn_context, :working_directory) ||
        Map.get(turn_context, "working_directory") || "."

    with {:ok, instructions} <- Instructions.discover(workspace, directory) do
      {:ok, %{"workspace" => Workspace.to_map(workspace), "instructions" => instructions}}
    end
  end

  defp validate_request_config(config) when config == %{}, do: :ok
  defp validate_request_config(_config), do: {:error, :coding_pack_agent_config_forbidden}

  defp normalize_entries(entries) when is_map(entries), do: {:ok, entries}

  defp normalize_entries(entries) when is_list(entries) do
    ids = Enum.map(entries, &entry_id/1)

    if Enum.any?(ids, &is_nil/1) or length(ids) != length(Enum.uniq(ids)),
      do: {:error, Error.new(:coding_tool_id_collision)},
      else: {:ok, Map.new(entries, fn entry -> {entry_id(entry), entry_value(entry)} end)}
  end

  defp normalize_entries(_entries), do: {:error, Error.new(:coding_tool_entries_invalid)}

  defp entry_id({id, _entry}) when is_binary(id), do: id
  defp entry_id(%{id: id}) when is_binary(id), do: id
  defp entry_id(_entry), do: nil
  defp entry_value({_id, entry}), do: entry
  defp entry_value(%{entry: entry}), do: entry

  defp known_tool_ids(ids) do
    unknown = Enum.uniq(ids) -- @tool_ids
    if unknown == [], do: :ok, else: {:error, Error.new(:unknown_coding_tool_id, %{ids: unknown})}
  end

  defp validate_entries(entries) do
    Enum.reduce_while(entries, :ok, fn
      {id, %{operation: %Operation{name: name}, handler: handler}}, :ok
      when name == id and (is_function(handler, 2) or is_function(handler, 3)) ->
        {:cont, :ok}

      {id, _entry}, :ok ->
        {:halt, {:error, Error.new(:coding_tool_entry_invalid, %{id: id})}}
    end)
  end

  defp digest(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
end
