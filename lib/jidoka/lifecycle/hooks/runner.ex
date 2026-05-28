defmodule Jidoka.Hooks.Runner do
  @moduledoc false

  require Logger

  alias Jidoka.Hooks.{AfterTurn, BeforeTurn, InterruptInput}
  alias Jidoka.Interrupt

  @spec run_before_turn([term()], BeforeTurn.t(), pos_integer()) ::
          {:ok, BeforeTurn.t()} | {:interrupt, Interrupt.t()} | {:error, term()}
  def run_before_turn(hooks, %BeforeTurn{} = input, timeout \\ Jidoka.Lifecycle.Timeouts.default_timeout_ms()) do
    Enum.reduce_while(hooks, {:ok, input}, fn hook, {:ok, input_acc} ->
      trace_hook(:before_turn, hook, :start, input_acc)

      case invoke_hook(hook, input_acc, timeout) do
        {:ok, overrides} ->
          with {:ok, input_acc} <- apply_before_turn_overrides(input_acc, overrides) do
            trace_hook(:before_turn, hook, :stop, input_acc, %{outcome: :ok})
            {:cont, {:ok, input_acc}}
          else
            {:error, reason} ->
              trace_hook(:before_turn, hook, :error, input_acc, %{error: Jidoka.Error.format(reason)})
              {:halt, {:error, reason}}
          end

        {:interrupt, interrupt} ->
          trace_hook(:before_turn, hook, :interrupt, input_acc, %{outcome: :interrupt})
          {:halt, {:interrupt, normalize_interrupt(interrupt)}}

        {:error, reason} ->
          trace_hook(:before_turn, hook, :error, input_acc, %{error: Jidoka.Error.format(reason)})
          {:halt, {:error, reason}}
      end
    end)
  end

  @spec run_after_turn([term()], AfterTurn.t(), pos_integer()) ::
          {:ok, AfterTurn.t()} | {:interrupt, Interrupt.t()} | {:error, term()}
  def run_after_turn(hooks, %AfterTurn{} = input, timeout \\ Jidoka.Lifecycle.Timeouts.default_timeout_ms()) do
    hooks
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, input}, fn hook, {:ok, input_acc} ->
      trace_hook(:after_turn, hook, :start, input_acc)

      case invoke_hook(hook, input_acc, timeout) do
        {:ok, {:ok, _} = outcome} ->
          trace_hook(:after_turn, hook, :stop, input_acc, %{outcome: :ok})
          {:cont, {:ok, %{input_acc | outcome: outcome}}}

        {:ok, {:error, _} = outcome} ->
          trace_hook(:after_turn, hook, :stop, input_acc, %{outcome: :error})
          {:cont, {:ok, %{input_acc | outcome: outcome}}}

        {:interrupt, interrupt} ->
          trace_hook(:after_turn, hook, :interrupt, input_acc, %{outcome: :interrupt})
          {:halt, {:interrupt, normalize_interrupt(interrupt)}}

        {:error, reason} ->
          trace_hook(:after_turn, hook, :error, input_acc, %{error: Jidoka.Error.format(reason)})
          {:halt, {:error, reason}}

        other ->
          trace_hook(:after_turn, hook, :error, input_acc, %{error: "invalid hook result"})

          {:halt,
           {:error,
            "after_turn hook must return {:ok, {:ok, result}}, {:ok, {:error, reason}}, {:interrupt, interrupt}, or {:error, reason}; got: #{inspect(other)}"}}
      end
    end)
  end

  @spec invoke_interrupt_hooks([term()], InterruptInput.t(), pos_integer()) :: :ok
  def invoke_interrupt_hooks(
        hooks,
        %InterruptInput{} = input,
        timeout \\ Jidoka.Lifecycle.Timeouts.default_timeout_ms()
      ) do
    hooks
    |> Enum.reverse()
    |> Enum.each(fn hook ->
      trace_hook(:on_interrupt, hook, :start, input)

      case invoke_hook(hook, input, timeout) do
        :ok ->
          trace_hook(:on_interrupt, hook, :stop, input, %{outcome: :ok})
          :ok

        {:error, reason} ->
          trace_hook(:on_interrupt, hook, :error, input, %{error: Jidoka.Error.format(reason)})

          Logger.warning(
            "Jidoka on_interrupt hook failed: #{Jidoka.Error.format(normalize_hook_error(:on_interrupt, reason, input.agent, input.request_id))}"
          )

        other ->
          trace_hook(:on_interrupt, hook, :error, input, %{error: "invalid hook result"})
          Logger.warning("Jidoka on_interrupt hook returned invalid result: #{inspect(other)}")
      end
    end)
  end

  @spec apply_before_turn_input(map(), BeforeTurn.t()) :: map()
  def apply_before_turn_input(params, %BeforeTurn{} = input) do
    params
    |> Map.put(:query, input.message)
    |> maybe_put_prompt(input.message)
    |> Map.put(:tool_context, input.context)
    |> Map.put(:runtime_context, input.context)
    |> maybe_put_optional(:allowed_tools, input.allowed_tools)
    |> maybe_put_optional(:llm_opts, input.llm_opts)
  end

  @spec interrupt_input(Jido.Agent.t(), String.t(), map(), Interrupt.t()) :: InterruptInput.t()
  def interrupt_input(agent, request_id, hook_meta, interrupt) do
    %InterruptInput{
      agent: agent,
      server: self(),
      request_id: request_id,
      message: hook_meta[:message] || "",
      context: hook_meta[:context] || %{},
      allowed_tools: hook_meta[:allowed_tools],
      llm_opts: hook_meta[:llm_opts] || [],
      metadata: hook_meta[:metadata] || %{},
      request_opts: hook_meta[:request_opts] || %{},
      interrupt: interrupt
    }
  end

  @spec normalize_hook_error(atom(), term(), Jido.Agent.t(), String.t() | nil) :: term()
  def normalize_hook_error(stage, reason, agent, request_id) do
    Jidoka.Error.Normalize.hook_error(stage, reason,
      agent_id: Map.get(agent, :id),
      request_id: request_id
    )
  end

  defp maybe_put_prompt(params, message) do
    if Map.has_key?(params, :prompt) do
      Map.put(params, :prompt, message)
    else
      params
    end
  end

  defp maybe_put_optional(params, _key, nil), do: params
  defp maybe_put_optional(params, key, value), do: Map.put(params, key, value)

  defp apply_before_turn_overrides(%BeforeTurn{} = input, overrides)
       when is_map(overrides) or is_list(overrides) do
    with {:ok, overrides} <- normalize_override_map(overrides) do
      allowed_keys = [:message, :context, :allowed_tools, :llm_opts, :metadata]

      case Map.keys(overrides) -- allowed_keys do
        [] ->
          with {:ok, context} <-
                 normalize_override_context(Map.get(overrides, :context)),
               {:ok, allowed_tools} <-
                 normalize_override_allowed_tools(Map.get(overrides, :allowed_tools)),
               {:ok, llm_opts} <- normalize_override_llm_opts(Map.get(overrides, :llm_opts)),
               {:ok, metadata} <- normalize_override_metadata(Map.get(overrides, :metadata)),
               {:ok, message} <-
                 normalize_override_message(Map.get(overrides, :message, input.message)) do
            {:ok,
             %BeforeTurn{
               input
               | message: message,
                 context: merge_optional(input.context, context),
                 allowed_tools: coalesce_optional(allowed_tools, input.allowed_tools),
                 llm_opts: coalesce_optional(llm_opts, input.llm_opts),
                 metadata: Map.merge(input.metadata, metadata)
             }}
          end

        invalid_keys ->
          {:error,
           "before_turn hook returned unsupported override keys: #{Enum.join(Enum.map(invalid_keys, &inspect/1), ", ")}"}
      end
    end
  end

  defp apply_before_turn_overrides(_input, other),
    do: {:error, "before_turn hook must return {:ok, map_or_keyword_overrides}, got: #{inspect(other)}"}

  defp normalize_override_message(message) when is_binary(message), do: {:ok, message}
  defp normalize_override_message(nil), do: {:ok, nil}

  defp normalize_override_message(other),
    do: {:error, "before_turn message override must be a string, got: #{inspect(other)}"}

  defp normalize_override_context(nil), do: {:ok, %{}}
  defp normalize_override_context(value) when is_map(value), do: {:ok, value}

  defp normalize_override_context(value) when is_list(value) do
    case Jidoka.Context.coerce_map(value) do
      {:ok, normalized} ->
        {:ok, normalized}

      :error ->
        {:error, "before_turn context override must be a map or keyword list, got: #{inspect(value)}"}
    end
  end

  defp normalize_override_context(other),
    do: {:error, "before_turn context override must be a map or keyword list, got: #{inspect(other)}"}

  defp normalize_override_allowed_tools(nil), do: {:ok, nil}
  defp normalize_override_allowed_tools(value) when is_list(value), do: {:ok, value}

  defp normalize_override_allowed_tools(other),
    do: {:error, "before_turn allowed_tools override must be a list, got: #{inspect(other)}"}

  defp normalize_override_llm_opts(nil), do: {:ok, nil}
  defp normalize_override_llm_opts(value) when is_list(value), do: {:ok, value}
  defp normalize_override_llm_opts(value) when is_map(value), do: {:ok, value}

  defp normalize_override_llm_opts(other),
    do: {:error, "before_turn llm_opts override must be a map or keyword list, got: #{inspect(other)}"}

  defp normalize_override_metadata(nil), do: {:ok, %{}}
  defp normalize_override_metadata(value) when is_map(value), do: {:ok, value}

  defp normalize_override_metadata(value) when is_list(value) do
    case Jidoka.Context.coerce_map(value) do
      {:ok, normalized} ->
        {:ok, normalized}

      :error ->
        {:error, "before_turn metadata override must be a map or keyword list, got: #{inspect(value)}"}
    end
  end

  defp normalize_override_metadata(other),
    do: {:error, "before_turn metadata override must be a map or keyword list, got: #{inspect(other)}"}

  defp normalize_override_map(overrides) when is_map(overrides), do: {:ok, overrides}

  defp normalize_override_map(overrides) when is_list(overrides) do
    case Jidoka.Context.coerce_map(overrides) do
      {:ok, normalized} ->
        {:ok, normalized}

      :error ->
        {:error, "before_turn hook must return {:ok, map_or_keyword_overrides}, got: #{inspect(overrides)}"}
    end
  end

  defp merge_optional(left, right) when is_map(right) and map_size(right) > 0,
    do: Map.merge(left || %{}, right)

  defp merge_optional(left, _right), do: left

  defp coalesce_optional(nil, fallback), do: fallback
  defp coalesce_optional(value, _fallback), do: value

  defp normalize_interrupt(%Interrupt{} = interrupt), do: interrupt

  defp normalize_interrupt(interrupt) when is_map(interrupt) or is_list(interrupt),
    do: Interrupt.new(interrupt)

  defp normalize_interrupt(other),
    do: Interrupt.new(%{kind: :interrupt, message: inspect(other), data: %{raw_interrupt: other}})

  defp invoke_hook(module, input, timeout) when is_atom(module) do
    invoke_with_timeout(fn -> module.call(input) end, timeout)
  end

  defp invoke_hook({module, function, args}, input, timeout) do
    invoke_with_timeout(fn -> apply(module, function, [input | args]) end, timeout)
  end

  defp invoke_hook(fun, input, timeout) when is_function(fun, 1) do
    invoke_with_timeout(fn -> fun.(input) end, timeout)
  end

  defp invoke_with_timeout(fun, timeout) do
    task = Task.async(fn -> safe_invoke(fun) end)

    case Task.yield(task, normalize_timeout(timeout)) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> result
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp normalize_timeout(_timeout), do: Jidoka.Lifecycle.Timeouts.default_timeout_ms()

  defp safe_invoke(fun) do
    {:ok, fun.()}
  rescue
    error ->
      {:error, Exception.message(error)}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp trace_hook(stage, hook, event, input, extra \\ %{}) do
    Jidoka.Trace.emit(
      :hook,
      Jidoka.Trace.correlation_refs(input)
      |> Map.merge(%{
        event: event,
        phase: stage,
        hook: hook_label(hook),
        request_id: input.request_id,
        agent_id: Map.get(input.agent, :id),
        context_keys: context_keys(input.context),
        allowed_tool_count: count_list(input.allowed_tools)
      })
      |> Map.merge(extra)
    )
  end

  defp hook_label(module) when is_atom(module) do
    case Jidoka.Hook.hook_name(module) do
      {:ok, name} -> name
      {:error, _reason} -> inspect(module)
    end
  end

  defp hook_label({module, function, args}), do: "#{inspect(module)}.#{function}/#{length(args) + 1}"
  defp hook_label(fun) when is_function(fun, 1), do: "anonymous_hook"
  defp hook_label(other), do: inspect(other)

  defp count_list(values) when is_list(values), do: length(values)
  defp count_list(_values), do: nil

  defp context_keys(context) when is_map(context) do
    context
    |> Jidoka.Context.strip_internal()
    |> Map.keys()
    |> Enum.map(&key_to_string/1)
    |> Enum.sort()
  end

  defp context_keys(_context), do: []

  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key), do: inspect(key)
end
