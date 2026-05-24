defmodule Jidoka.Guardrails.Runner do
  @moduledoc false

  alias Jidoka.Guardrails.{Input, Output, Tool}
  alias Jidoka.Interrupt

  @guardrail_timeout_ms 5_000

  @spec run_input([Jidoka.Guardrails.guardrail_ref()], Input.t()) ::
          :ok | {:error, String.t(), term()} | {:interrupt, String.t(), Interrupt.t()}
  def run_input(guardrails, %Input{} = input) do
    run_guardrails(guardrails, input)
  end

  @spec run_output([Jidoka.Guardrails.guardrail_ref()], Output.t()) ::
          :ok | {:error, String.t(), term()} | {:interrupt, String.t(), Interrupt.t()}
  def run_output(guardrails, %Output{} = input) do
    run_guardrails(guardrails, input)
  end

  @spec run_guardrails([Jidoka.Guardrails.guardrail_ref()], struct()) ::
          :ok | {:error, String.t(), term()} | {:interrupt, String.t(), Interrupt.t()}
  def run_guardrails(guardrails, input) do
    Enum.reduce_while(guardrails, :ok, fn guardrail, :ok ->
      label = guardrail_label(guardrail)
      trace_guardrail(input, label, :start)

      case invoke_guardrail(guardrail, input) do
        result when result in [:ok, :cont] ->
          trace_guardrail(input, label, :allow, %{outcome: :allow})
          {:cont, :ok}

        {:block, reason} ->
          trace_guardrail(input, label, :block, %{outcome: :block, error: Jidoka.Error.format(reason)})
          {:halt, {:error, label, reason}}

        {:error, reason} ->
          trace_guardrail(input, label, :error, %{outcome: :error, error: Jidoka.Error.format(reason)})
          {:halt, {:error, label, reason}}

        {:interrupt, interrupt} ->
          trace_guardrail(input, label, :interrupt, %{outcome: :interrupt})
          {:halt, {:interrupt, label, normalize_interrupt(interrupt)}}

        other ->
          trace_guardrail(input, label, :error, %{outcome: :error, error: "invalid guardrail result"})
          {:halt, {:error, label, invalid_result_message(other)}}
      end
    end)
  end

  @spec normalize_guardrail_error(atom(), term(), term(), Jido.Agent.t(), String.t() | nil) :: Exception.t()
  def normalize_guardrail_error(stage, label, reason, agent, request_id) do
    Jidoka.Error.Normalize.guardrail_error(stage, label, reason,
      agent_id: Map.get(agent, :id),
      request_id: request_id
    )
  end

  defp invalid_result_message(other) do
    "controls must return :cont, :ok, {:block, reason}, {:error, reason}, or {:interrupt, interrupt}; got: #{inspect(other)}"
  end

  defp guardrail_label(module) when is_atom(module) do
    case Jidoka.Guardrail.guardrail_name(module) do
      {:ok, name} -> name
      {:error, _reason} -> inspect(module)
    end
  end

  defp guardrail_label({module, function, args}),
    do: "#{inspect(module)}.#{function}/#{length(args) + 1}"

  defp guardrail_label(fun) when is_function(fun, 1), do: "anonymous_guardrail"

  defp invoke_guardrail(module, input) when is_atom(module) do
    invoke_with_timeout(fn -> module.call(input) end)
  end

  defp invoke_guardrail({module, function, args}, input) do
    invoke_with_timeout(fn -> apply(module, function, [input | args]) end)
  end

  defp invoke_guardrail(fun, input) when is_function(fun, 1) do
    invoke_with_timeout(fn -> fun.(input) end)
  end

  defp invoke_with_timeout(fun) do
    task = Task.async(fn -> safe_invoke(fun) end)

    case Task.yield(task, @guardrail_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> result
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  defp safe_invoke(fun) do
    {:ok, fun.()}
  rescue
    error ->
      {:error, Exception.message(error)}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp normalize_interrupt(%Interrupt{} = interrupt), do: interrupt
  defp normalize_interrupt(interrupt), do: Interrupt.new(interrupt)

  defp trace_guardrail(input, label, event, extra \\ %{}) do
    Jidoka.Trace.emit(
      :guardrail,
      Map.merge(
        %{
          event: event,
          phase: guardrail_phase(input),
          guardrail: label,
          request_id: Map.get(input, :request_id),
          agent_id: input |> Map.get(:agent) |> agent_id(),
          tool_name: Map.get(input, :tool_name),
          context_keys: input |> Map.get(:context, %{}) |> context_keys()
        },
        extra
      )
    )
  end

  defp guardrail_phase(%Input{}), do: :input
  defp guardrail_phase(%Output{}), do: :output
  defp guardrail_phase(%Tool{}), do: :tool

  defp agent_id(%Jido.Agent{} = agent), do: Map.get(agent, :id)
  defp agent_id(_agent), do: nil

  defp context_keys(context) do
    if is_map(context) do
      context
      |> Jidoka.Context.strip_internal()
      |> Map.keys()
      |> Enum.map(&key_to_string/1)
      |> Enum.sort()
    else
      []
    end
  end

  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key), do: inspect(key)
end
