defmodule Jidoka.Operation.Source.Handoff do
  @moduledoc """
  Operation source for conversation handoff ownership.

  Handoff operations record that a target agent owns future turns for a
  conversation. The operation returns data to the current turn; routing future
  turns through that owner remains an application/harness concern.
  """

  @behaviour Jidoka.Operation.Source

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Context
  alias Jidoka.Effect
  alias Jidoka.Handoff
  alias Jidoka.Schema

  @type forward_context ::
          :public | :none | {:only, [atom() | String.t()]} | {:except, [atom() | String.t()]}
  @type target :: :auto | {:peer, String.t()} | {:peer, {:context, atom() | String.t()}}

  @type t :: %__MODULE__{
          agent: module(),
          name: String.t(),
          description: String.t() | nil,
          target: target(),
          forward_context: forward_context(),
          metadata: map()
        }

  @schema Zoi.struct(
            __MODULE__,
            %{
              agent: Zoi.atom() |> Zoi.nullish(),
              name: Zoi.string() |> Zoi.nullish(),
              description: Zoi.string() |> Zoi.nullish(),
              target: Zoi.any() |> Zoi.default(:auto),
              forward_context: Zoi.any() |> Zoi.default(:public),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    with {:ok, agent} <- normalize_agent(Schema.get_key(attrs, :agent)),
         {:ok, name} <-
           normalize_name(Schema.get_key(attrs, :name) || Schema.get_key(attrs, :as), agent),
         {:ok, target} <- normalize_target(Schema.get_key(attrs, :target, :auto)),
         {:ok, forward_context} <-
           normalize_forward_context(Schema.get_key(attrs, :forward_context, :public)),
         {:ok, metadata} <- normalize_metadata(Schema.get_key(attrs, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         agent: agent,
         name: name,
         description: Schema.get_key(attrs, :description),
         target: target,
         forward_context: forward_context,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, source} -> source
      {:error, reason} -> raise ArgumentError, "invalid handoff source: #{inspect(reason)}"
    end
  end

  @impl true
  def operations(%__MODULE__{} = source, _opts) do
    {:ok,
     [
       Operation.new!(
         name: source.name,
         description:
           source.description ||
             "Transfer future conversation ownership to #{inspect(source.agent)}.",
         idempotency: :unsafe_once,
         metadata:
           source.metadata
           |> Map.merge(%{
             "source" => "handoff",
             "kind" => "handoff",
             "agent" => inspect(source.agent),
             "target" => inspect(source.target),
             "forward_context" => inspect(source.forward_context),
             "parameters_schema" => handoff_schema()
           })
       )
     ]}
  end

  @impl true
  def capability(%__MODULE__{} = source, _opts) do
    {:ok,
     fn
       %Effect.Intent{kind: :operation, payload: payload}, %Effect.Journal{}, %Context{} = context ->
         with {:ok, request} <- Effect.OperationRequest.from_input(payload),
              :ok <- ensure_operation_name(source, request.name),
              {:ok, handoff} <- build_handoff(source, request, context) do
           Jidoka.Handoff.OwnerStore.put_owner(handoff.conversation_id, handoff)

           {:ok,
            %{
              handoff: project_handoff(handoff),
              owner: owner_projection(handoff)
            }}
         end

       %Effect.Intent{kind: kind}, _journal, %Context{} ->
         {:error, {:unsupported_effect_kind, kind}}
     end}
  end

  defp handoff_schema do
    %{
      "type" => "object",
      "properties" => %{
        "message" => %{"type" => "string", "description" => "Message for the target agent."},
        "summary" => %{"type" => "string", "description" => "Optional conversation summary."},
        "reason" => %{"type" => "string", "description" => "Optional transfer reason."},
        "conversation_id" => %{"type" => "string", "description" => "Optional conversation id."},
        "context" => %{"type" => "object", "description" => "Optional target-local context."}
      },
      "required" => ["message"]
    }
  end

  defp build_handoff(%__MODULE__{} = source, request, context) do
    arguments = request.arguments
    public_context = public_context_data(context)

    with {:ok, message} <- required_string(arguments, :message),
         conversation_id <- conversation_id(arguments, public_context),
         forwarded_context <- child_context(source, context, arguments),
         {:ok, to_agent_id} <- target_agent_id(source, conversation_id, public_context) do
      Handoff.new(
        conversation_id: conversation_id,
        from_agent: from_agent(context),
        to_agent: source.agent,
        to_agent_id: to_agent_id,
        name: source.name,
        message: message,
        summary: optional_string(arguments, :summary),
        reason: optional_string(arguments, :reason),
        context: forwarded_context,
        request_id: request.request_id,
        metadata: source.metadata
      )
    end
  end

  defp child_context(%__MODULE__{} = source, parent_context, arguments) do
    parent_context = parent_context |> public_context_data() |> forward_context(source.forward_context)

    case Schema.get_key(arguments, :context, %{}) do
      task_context when is_map(task_context) -> Map.merge(parent_context, task_context)
      _other -> parent_context
    end
  end

  defp conversation_id(arguments, context) do
    context_value(arguments, :conversation_id) ||
      context_value(arguments, :conversation) ||
      context_value(context, :conversation_id) ||
      context_value(context, :conversation) ||
      context_value(context, :session_id)
  end

  defp public_context_data(%Context{} = context), do: Context.data(context)

  defp target_agent_id(%__MODULE__{target: :auto, name: name}, nil, _context), do: {:ok, name}

  defp target_agent_id(%__MODULE__{target: :auto, name: name}, conversation_id, _context) do
    {:ok, "#{conversation_id}:#{name}"}
  end

  defp target_agent_id(%__MODULE__{target: {:peer, peer_id}}, _conversation_id, context) do
    resolve_peer_id(peer_id, context)
  end

  defp target_agent_id(%__MODULE__{target: {:peer, {:context, key}}}, _conversation_id, context) do
    case context_value(context, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_handoff_peer_context, key}}
    end
  end

  defp resolve_peer_id(peer_id, _context) when is_binary(peer_id) and peer_id != "",
    do: {:ok, peer_id}

  defp resolve_peer_id(peer_id, _context), do: {:error, {:invalid_handoff_peer_id, peer_id}}

  defp owner_projection(%Handoff{} = handoff) do
    %{
      conversation_id: handoff.conversation_id,
      agent: inspect(handoff.to_agent),
      agent_id: handoff.to_agent_id,
      name: handoff.name
    }
  end

  defp project_handoff(%Handoff{} = handoff) do
    %{
      id: handoff.id,
      conversation_id: handoff.conversation_id,
      from_agent: handoff.from_agent,
      to_agent: inspect(handoff.to_agent),
      to_agent_id: handoff.to_agent_id,
      name: handoff.name,
      message: handoff.message,
      summary: handoff.summary,
      reason: handoff.reason,
      context: handoff.context,
      request_id: handoff.request_id,
      metadata: handoff.metadata
    }
  end

  defp from_agent(context) do
    case spec_id(context) do
      id when is_binary(id) -> id
      _other -> context |> runtime_value(:agent_module) |> maybe_inspect()
    end
  end

  defp spec_id(%Context{spec: %{id: id}}), do: id

  defp spec_id(context) do
    case runtime_value(context, :jidoka_spec) do
      %{id: id} -> id
      _other -> nil
    end
  end

  defp runtime_value(%Context{} = context, key), do: Context.get_runtime(context, key)

  defp maybe_inspect(nil), do: nil
  defp maybe_inspect(value) when is_binary(value), do: value
  defp maybe_inspect(value), do: inspect(value)

  defp required_string(params, key) do
    case context_value(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:invalid_handoff_payload, key}}
          value -> {:ok, value}
        end

      value ->
        {:error, {:invalid_handoff_payload, {key, value}}}
    end
  end

  defp optional_string(params, key) do
    case context_value(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      _other ->
        nil
    end
  end

  defp context_value(%{} = map, key) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp context_value(%{} = map, key) when is_binary(key), do: Map.get(map, key)
  defp context_value(_map, _key), do: nil

  defp ensure_operation_name(%__MODULE__{name: expected}, name) do
    if name == expected, do: :ok, else: {:error, {:missing_operation_handler, name}}
  end

  defp forward_context(context, :public) when is_map(context), do: context
  defp forward_context(_context, :none), do: %{}

  defp forward_context(context, {:only, keys}) when is_map(context) and is_list(keys) do
    keys
    |> Enum.reduce(%{}, fn key, acc ->
      case fetch_context(context, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp forward_context(context, {:except, keys}) when is_map(context) and is_list(keys) do
    blocked = MapSet.new(Enum.flat_map(keys, &[&1, to_string(&1)]))
    Map.reject(context, fn {key, _value} -> MapSet.member?(blocked, key) end)
  end

  defp forward_context(_context, _policy), do: %{}

  defp fetch_context(context, key) when is_atom(key) do
    case Map.fetch(context, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(context, Atom.to_string(key))
    end
  end

  defp fetch_context(context, key), do: Map.fetch(context, key)

  defp normalize_agent(agent) when is_atom(agent) do
    with {:module, _module} <- Code.ensure_compiled(agent),
         true <- function_exported?(agent, :spec, 0) do
      {:ok, agent}
    else
      {:error, reason} -> {:error, {:invalid_handoff_module, agent, reason}}
      false -> {:error, {:invalid_handoff_module, agent, :missing_spec}}
    end
  end

  defp normalize_agent(agent), do: {:error, {:invalid_handoff_module, agent}}

  defp normalize_name(nil, agent) do
    agent
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> normalize_name(agent)
  end

  defp normalize_name(name, _agent) when is_atom(name) and not is_nil(name) do
    name |> Atom.to_string() |> normalize_name(nil)
  end

  defp normalize_name(name, _agent) when is_binary(name) do
    name = String.trim(name)

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) do
      {:ok, name}
    else
      {:error, {:invalid_handoff_name, name}}
    end
  end

  defp normalize_name(name, _agent), do: {:error, {:invalid_handoff_name, name}}

  defp normalize_target(target) when target in [:auto, "auto"], do: {:ok, :auto}
  defp normalize_target({:peer, peer_id}) when is_binary(peer_id), do: {:ok, {:peer, peer_id}}

  defp normalize_target({:peer, {:context, key}})
       when is_atom(key) or is_binary(key),
       do: {:ok, {:peer, {:context, key}}}

  defp normalize_target(target), do: {:error, {:invalid_handoff_target, target}}

  defp normalize_forward_context(policy) when policy in [:public, :none], do: {:ok, policy}

  defp normalize_forward_context({mode, keys} = policy)
       when mode in [:only, :except] and is_list(keys) do
    {:ok, policy}
  end

  defp normalize_forward_context(policy), do: {:error, {:invalid_handoff_forward_context, policy}}

  defp normalize_metadata(nil), do: {:ok, %{}}
  defp normalize_metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  defp normalize_metadata(metadata), do: {:error, {:invalid_handoff_metadata, metadata}}
end
