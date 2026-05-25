defmodule Jidoka.Guardrails.Runner do
  @moduledoc false

  alias Jidoka.Guardrails.{Input, Output, Tool}
  alias Jidoka.Interrupt

  @guardrail_timeout_ms 5_000
  @type control_result(input) :: {:ok, input} | {:error, String.t(), term()} | {:interrupt, String.t(), Interrupt.t()}

  @spec run_input([Jidoka.Guardrails.guardrail_ref()], Input.t()) ::
          control_result(Input.t())
  def run_input(guardrails, %Input{} = input) do
    run_controls(guardrails, input)
  end

  @spec run_output([Jidoka.Guardrails.guardrail_ref()], Output.t()) ::
          control_result(Output.t())
  def run_output(guardrails, %Output{} = input) do
    run_controls(guardrails, input)
  end

  @spec run_guardrails([Jidoka.Guardrails.guardrail_ref()], struct()) ::
          :ok | {:error, String.t(), term()} | {:interrupt, String.t(), Interrupt.t()}
  def run_guardrails(guardrails, input) do
    case run_controls(guardrails, input) do
      {:ok, _input} -> :ok
      other -> other
    end
  end

  @spec run_controls([Jidoka.Guardrails.guardrail_ref()], struct()) ::
          control_result(struct())
  def run_controls(guardrails, input) do
    Enum.reduce_while(guardrails, {:ok, input}, fn guardrail, {:ok, input_acc} ->
      label = guardrail_label(guardrail)
      trace_guardrail(input_acc, label, :start)

      case invoke_guardrail(guardrail, input_acc) do
        result when result in [:ok, :cont, :allow] ->
          trace_guardrail(input_acc, label, :allow, %{outcome: :allow})
          {:cont, {:ok, input_acc}}

        {:transform, transform} ->
          case apply_transform(input_acc, transform) do
            {:ok, transformed_input} ->
              case validate_transformed_input(transformed_input) do
                :ok ->
                  trace_guardrail(input_acc, label, :transform, %{outcome: :transform})
                  {:cont, {:ok, transformed_input}}

                {:error, reason} ->
                  trace_guardrail(input_acc, label, :error, %{outcome: :error, error: reason})
                  {:halt, {:error, label, reason}}
              end

            {:error, reason} ->
              trace_guardrail(input_acc, label, :error, %{outcome: :error, error: Jidoka.Error.format(reason)})
              {:halt, {:error, label, reason}}
          end

        {:block, reason} ->
          trace_guardrail(input_acc, label, :block, %{outcome: :block, error: Jidoka.Error.format(reason)})
          {:halt, {:error, label, reason}}

        {:error, reason} ->
          trace_guardrail(input_acc, label, :error, %{outcome: :error, error: Jidoka.Error.format(reason)})
          {:halt, {:error, label, reason}}

        {:interrupt, interrupt} ->
          trace_guardrail(input_acc, label, :interrupt, %{outcome: :interrupt})
          {:halt, {:interrupt, label, normalize_interrupt(interrupt)}}

        other ->
          trace_guardrail(input_acc, label, :error, %{outcome: :error, error: "invalid guardrail result"})
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
    "controls must return :allow, :cont, :ok, {:transform, updates}, {:block, reason}, {:error, reason}, or {:interrupt, interrupt}; got: #{inspect(other)}"
  end

  defp apply_transform(%Tool{}, _transform) do
    {:error, "operation controls cannot transform operation inputs in this version"}
  end

  defp apply_transform(%{} = input, %{__struct__: module} = transformed) do
    if module == input.__struct__ do
      {:ok, transformed}
    else
      {:error, transform_type_error(input, transformed)}
    end
  end

  defp apply_transform(%{} = input, transform)
       when not is_struct(transform) and (is_map(transform) or is_list(transform)) do
    with {:ok, updates} <- normalize_transform_updates(transform),
         :ok <- validate_transform_keys(input, updates) do
      {:ok, struct(input, updates)}
    end
  end

  defp apply_transform(input, transform), do: {:error, transform_type_error(input, transform)}

  defp normalize_transform_updates(updates) when is_map(updates), do: {:ok, updates}

  defp normalize_transform_updates(updates) when is_list(updates) do
    if Keyword.keyword?(updates) do
      {:ok, Map.new(updates)}
    else
      {:error, "control transform updates must be a map, keyword list, or replacement control input struct"}
    end
  end

  defp validate_transform_keys(input, updates) do
    allowed_keys =
      input
      |> Map.from_struct()
      |> Map.keys()
      |> MapSet.new()

    unknown_keys = updates |> Map.keys() |> Enum.reject(&MapSet.member?(allowed_keys, &1))

    case unknown_keys do
      [] -> :ok
      _ -> {:error, "control transform contains unsupported keys: #{inspect(unknown_keys)}"}
    end
  end

  defp transform_type_error(input, transform) do
    "control transform must return #{inspect(input.__struct__)}, a map, or a keyword list; got: #{inspect(transform)}"
  end

  defp validate_transformed_input(%Input{context: context}) when not is_map(context) do
    {:error, "input control transforms must keep context as a map"}
  end

  defp validate_transformed_input(%Input{metadata: metadata}) when not is_map(metadata) do
    {:error, "input control transforms must keep metadata as a map"}
  end

  defp validate_transformed_input(%Input{llm_opts: llm_opts}) when not is_list(llm_opts) do
    {:error, "input control transforms must keep llm_opts as a keyword list"}
  end

  defp validate_transformed_input(%Output{context: context}) when not is_map(context) do
    {:error, "result control transforms must keep context as a map"}
  end

  defp validate_transformed_input(%Output{metadata: metadata}) when not is_map(metadata) do
    {:error, "result control transforms must keep metadata as a map"}
  end

  defp validate_transformed_input(%Output{llm_opts: llm_opts}) when not is_list(llm_opts) do
    {:error, "result control transforms must keep llm_opts as a keyword list"}
  end

  defp validate_transformed_input(%Output{outcome: {:ok, _result}}), do: :ok
  defp validate_transformed_input(%Output{outcome: {:error, _reason}}), do: :ok

  defp validate_transformed_input(%Output{}) do
    {:error, "result control transforms must keep outcome as {:ok, result} or {:error, reason}"}
  end

  defp validate_transformed_input(_input), do: :ok

  defp guardrail_label(module) when is_atom(module) do
    case Jidoka.Guardrail.guardrail_name(module) do
      {:ok, name} -> name
      {:error, _reason} -> inspect(module)
    end
  end

  defp guardrail_label(%Jidoka.Control.Operation{ref: ref}), do: guardrail_label(ref)

  defp guardrail_label({module, function, args}),
    do: "#{inspect(module)}.#{function}/#{length(args) + 1}"

  defp guardrail_label(fun) when is_function(fun, 1), do: "anonymous_guardrail"

  defp invoke_guardrail(module, input) when is_atom(module) do
    invoke_with_timeout(fn -> module.call(input) end)
  end

  defp invoke_guardrail(%Jidoka.Control.Operation{} = operation, input) do
    if operation_matches?(operation, input) do
      invoke_guardrail(operation.ref, input)
    else
      :cont
    end
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

  defp operation_matches?(%Jidoka.Control.Operation{match: nil}, _input), do: true
  defp operation_matches?(%Jidoka.Control.Operation{match: match}, %Tool{} = input), do: match_tool?(match, input)
  defp operation_matches?(%Jidoka.Control.Operation{}, _input), do: false

  defp match_tool?(match, input) when is_map(match) do
    Enum.all?(match, fn
      {:kind, kind} -> kind in [:action, :tool]
      {:name, name} -> to_string(input.tool_name) == to_string(name)
      {:credential, credential_match} -> match_credentials?(credential_match, input)
      _other -> false
    end)
  end

  defp match_credentials?(credential_match, %Tool{} = input) when is_map(credential_match) do
    input
    |> operation_credentials()
    |> Enum.any?(&credential_matches?(&1, credential_match))
  end

  defp match_credentials?(_credential_match, _input), do: false

  defp operation_credentials(%Tool{} = input) do
    Jidoka.Credential.references([input.arguments, input.context])
  end

  defp credential_matches?(%Jidoka.Credential{} = credential, match) do
    Enum.all?(match, fn
      {:provider, provider} -> credential.provider == to_string(provider)
      {:account, account} -> credential.account == to_string(account)
      {:actor, actor} -> credential.actor == to_string(actor)
      {:tenant, tenant} -> credential.tenant == to_string(tenant)
      {:scope, scope} -> to_string(scope) in credential.scopes
      {:scopes, scopes} when is_list(scopes) -> Enum.all?(scopes, &(to_string(&1) in credential.scopes))
      {:risk, risk} -> credential.risk == risk
      {:confirmation_required, required?} -> credential.confirmation_required == required?
      _other -> false
    end)
  end

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
        Jidoka.Trace.correlation_refs(input)
      )
      |> Map.merge(extra)
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
