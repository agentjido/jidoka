defmodule Jidoka.Handoff do
  @moduledoc """
  First-class conversation ownership transfer returned by Jidoka agents.

  A handoff is distinct from a subagent call. Subagents are bounded delegation
  for one task inside the current turn; handoffs assign future turns for a
  conversation to another agent until the owner is reset.
  """

  @context_key :__jidoka_conversation__
  @request_id_key :__jidoka_request_id__
  @server_key :__jidoka_server__
  @from_agent_key :__jidoka_from_agent__

  @enforce_keys [:id, :conversation_id, :from_agent, :to_agent, :to_agent_id, :name, :message, :context]
  defstruct [
    :id,
    :conversation_id,
    :from_agent,
    :to_agent,
    :to_agent_id,
    :name,
    :message,
    :summary,
    :reason,
    :context,
    :request_id,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          conversation_id: String.t() | nil,
          from_agent: String.t() | module() | nil,
          to_agent: module(),
          to_agent_id: String.t(),
          name: String.t(),
          message: String.t(),
          summary: String.t() | nil,
          reason: String.t() | nil,
          context: map(),
          request_id: String.t() | nil,
          metadata: map()
        }

  @doc false
  @spec context_key() :: atom()
  def context_key, do: @context_key

  @doc false
  @spec request_id_key() :: atom()
  def request_id_key, do: @request_id_key

  @doc false
  @spec server_key() :: atom()
  def server_key, do: @server_key

  @doc false
  @spec from_agent_key() :: atom()
  def from_agent_key, do: @from_agent_key

  @doc false
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      id: normalize_id(Map.get(attrs, :id)),
      conversation_id: Map.get(attrs, :conversation_id),
      from_agent: Map.get(attrs, :from_agent),
      to_agent: Map.fetch!(attrs, :to_agent),
      to_agent_id: Map.fetch!(attrs, :to_agent_id),
      name: Map.fetch!(attrs, :name),
      message: Map.fetch!(attrs, :message),
      summary: Map.get(attrs, :summary),
      reason: Map.get(attrs, :reason),
      context: Map.fetch!(attrs, :context),
      request_id: Map.get(attrs, :request_id),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  defp normalize_id(id) when is_binary(id) and id != "", do: id
  defp normalize_id(_id), do: Jido.Signal.ID.generate!()
end
