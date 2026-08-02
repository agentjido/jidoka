defmodule Jidoka.Chat do
  @moduledoc false

  alias Jidoka.Error
  alias Jidoka.Adapter.Jido.AgentServer
  alias Jidoka.Session.Data, as: Session
  alias Jidoka.Snapshot
  alias Jidoka.Turn
  alias Jidoka.Turn.Execution, as: TurnExecution

  @type result ::
          {:ok, String.t()}
          | {:ok, Jidoka.Session.t(), String.t()}
          | {:hibernate, Snapshot.t()}
          | {:hibernate, Jidoka.Session.t(), Snapshot.t()}
          | {:error, term()}

  defguardp is_server_ref(server)
            when is_pid(server) or is_binary(server) or
                   (is_tuple(server) and tuple_size(server) == 3)

  @spec run(Session.t() | term(), String.t(), keyword()) :: result()
  def run(target, input, opts \\ [])

  def run(%Session{} = session, input, opts) when is_binary(input) and is_list(opts) do
    case Jidoka.Session.chat(session, input, opts) do
      {:ok, session, content} -> {:ok, session, content}
      {:hibernate, session, snapshot} -> {:hibernate, session, snapshot}
      {:error, reason} -> {:error, Error.normalize(reason, operation: :chat, phase: :session)}
    end
  end

  def run(server, input, opts)
      when is_binary(input) and is_server_ref(server) and is_list(opts) do
    with {:ok, %Turn.Result{content: content}} <- AgentServer.turn(server, input, opts) do
      {:ok, content}
    end
  end

  def run(spec_input, input, opts) when is_binary(input) and is_list(opts) do
    with {:ok, %Turn.Result{content: content}} <- run_turn(spec_input, input, opts) do
      {:ok, content}
    end
  end

  defp run_turn(spec_input, input, opts) do
    case TurnExecution.run(spec_input, input, opts) do
      {:ok, _result} = ok -> ok
      {:hibernate, _snapshot} = hibernate -> hibernate
      {:error, reason} -> {:error, Error.normalize(reason, operation: :turn, phase: :harness)}
    end
  end
end
