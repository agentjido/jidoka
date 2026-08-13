defmodule Jidoka.ModelPolicy do
  @moduledoc """
  Routes, retries, and falls back model calls at the LLM effect boundary.

  Pass a policy with the `model_policy:` run option. A policy has an ordered
  model list, an optional selector, and a retry policy. The selector receives
  the model list and the trusted LLM context for each model call.

  Model retries stay inside one LLM effect. They do not retry operation
  effects. The winning decision and the effect result contain an ordered
  `:model_attempts` list.
  """

  alias Jidoka.Config
  alias Jidoka.Context
  alias Jidoka.Effect
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.Limits
  alias Jidoka.Schema
  alias Jidoka.Workflow.RetryPolicy

  @failure_classes [:transient, :permanent]
  @transient_reasons [
    :closed,
    :connection_closed,
    :econnrefused,
    :enetdown,
    :enetunreach,
    :ehostunreach,
    :overloaded,
    :rate_limited,
    :service_unavailable,
    :timeout
  ]

  @enforce_keys [:models, :select, :classify, :retry, :sleep]
  defstruct models: [], select: nil, classify: nil, retry: nil, sleep: &Process.sleep/1

  @type selector ::
          ([LLMDB.Model.t()], Context.t() ->
             Config.model_spec() | [Config.model_spec()] | {:ok, term()} | {:error, term()})
          | module()
          | nil
  @type classifier :: (term() -> :transient | :permanent) | module() | nil
  @type t :: %__MODULE__{
          models: [LLMDB.Model.t()],
          select: selector(),
          classify: classifier(),
          retry: RetryPolicy.t(),
          sleep: (non_neg_integer() -> term())
        }

  @callback select([LLMDB.Model.t()], Context.t()) ::
              Config.model_spec() | [Config.model_spec()] | {:ok, term()} | {:error, term()}
  @callback classify(term()) :: :transient | :permanent
  @optional_callbacks select: 2, classify: 1

  @doc "Builds a model policy from a keyword list or map."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      new(Map.new(attrs))
    else
      {:error, {:invalid_model_policy, attrs}}
    end
  end

  def new(attrs) when is_map(attrs) do
    with {:ok, models} <- normalize_models(Schema.get_key(attrs, :models, [])),
         {:ok, select} <- normalize_callback(Schema.get_key(attrs, :select), :select, 2),
         {:ok, classify} <- normalize_callback(Schema.get_key(attrs, :classify), :classify, 1),
         {:ok, retry} <- normalize_retry(Schema.get_key(attrs, :retry)),
         {:ok, sleep} <- normalize_sleep(Schema.get_key(attrs, :sleep)) do
      {:ok,
       %__MODULE__{
         models: models,
         select: select,
         classify: classify,
         retry: retry,
         sleep: sleep
       }}
    end
  end

  def new(attrs), do: {:error, {:invalid_model_policy, attrs}}

  @doc "Builds a model policy and raises if it is not valid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "invalid model policy: #{inspect(reason)}"
    end
  end

  @doc "Returns the built-in failure class for a model error."
  @spec classify(term()) :: :transient | :permanent
  def classify(%Req.TransportError{}), do: :transient
  def classify(%{status: status}) when status in [408, 409, 425, 429], do: :transient
  def classify(%{status: status}) when is_integer(status) and status >= 500, do: :transient
  def classify(%{reason: reason}), do: classify(reason)
  def classify({:capability_timeout, :llm, _timeout_ms}), do: :transient
  def classify({:error, reason}), do: classify(reason)
  def classify({reason, _detail}) when reason in @transient_reasons, do: :transient
  def classify(reason) when reason in @transient_reasons, do: :transient
  def classify(_reason), do: :permanent

  @doc false
  @spec wrap(Capabilities.t(), keyword() | map() | t() | nil) ::
          {:ok, Capabilities.t()} | {:error, term()}
  def wrap(%Capabilities{} = capabilities, policy), do: wrap(capabilities, policy, [])

  @doc false
  @spec wrap(Capabilities.t(), keyword() | map() | t() | nil, keyword()) ::
          {:ok, Capabilities.t()} | {:error, term()}
  def wrap(%Capabilities{} = capabilities, nil, _opts), do: {:ok, capabilities}

  def wrap(%Capabilities{} = capabilities, %__MODULE__{} = policy, opts) do
    llm = policy_capability(capabilities.llm, policy, Keyword.get(opts, :runtime_limits))
    {:ok, %Capabilities{capabilities | llm: llm}}
  end

  def wrap(%Capabilities{} = capabilities, attrs, opts) do
    with {:ok, policy} <- new(attrs) do
      wrap(capabilities, policy, opts)
    end
  end

  @doc false
  @spec configure_llm_opts(keyword(), Config.model(), keyword()) :: keyword()
  def configure_llm_opts(llm_opts, model, runtime_opts) do
    if is_nil(Keyword.get(runtime_opts, :model_policy)) do
      Keyword.put_new(llm_opts, :model, model)
    else
      Keyword.delete(llm_opts, :model)
    end
  end

  @doc false
  @spec error_metadata(term()) :: map()
  def error_metadata({:model_policy_failed, attempts, _reason}) when is_list(attempts),
    do: %{model_attempts: attempts}

  def error_metadata(_reason), do: %{}

  defp policy_capability(llm, %__MODULE__{} = policy, limits) do
    fn %Effect.Intent{} = intent, %Effect.Journal{} = journal, %Context{} = context ->
      case selected_models(policy, intent, context) do
        {:ok, models} ->
          call = %{
            llm: llm,
            intent: intent,
            journal: journal,
            context: context,
            policy: policy,
            limits: limits
          }

          call_models(models, call, [])

        {:error, reason} ->
          {:error, {:model_policy_failed, [], reason}}
      end
    end
  end

  defp selected_models(%__MODULE__{} = policy, %Effect.Intent{} = intent, %Context{} = context) do
    with {:ok, models} <- base_models(policy.models, intent),
         {:ok, selected} <- select(policy.select, models, context),
         {:ok, selected} <- normalize_selection(selected),
         :ok <- require_models(selected) do
      {:ok, selected}
    end
  end

  defp base_models([], %Effect.Intent{payload: payload}) do
    case Schema.fetch_key(payload, :model) do
      {:ok, model} -> normalize_models([model])
      :error -> {:error, :missing_model_policy_models}
    end
  end

  defp base_models(models, _intent), do: {:ok, models}

  defp select(nil, models, _context), do: {:ok, models}

  defp select(select, models, context) when is_function(select, 2),
    do: safe_callback(fn -> select.(models, context) end, :model_selector_failed)

  defp select(select, models, context) when is_atom(select),
    do: safe_callback(fn -> select.select(models, context) end, :model_selector_failed)

  defp call_models([], _call, attempts) do
    {:error, {:model_policy_failed, attempts, :models_exhausted}}
  end

  defp call_models([model | rest], call, attempts) do
    call_model(model, rest, call, 1, attempts)
  end

  defp call_model(model, rest, call, model_attempt, attempts) do
    routed_intent = route_intent(call.intent, model)

    case Limits.check_provider_attempt(call.journal, length(attempts), call.limits) do
      :ok ->
        case safe_capability_call(call.llm, routed_intent, call.journal, call.context) do
          {:ok, output} ->
            attempts = attempts ++ [attempt(model, attempts, model_attempt, :ok, nil)]
            {:ok, attach_metadata(output, model, attempts)}

          {:error, reason} ->
            handle_model_failure(reason, model, rest, call, model_attempt, attempts)
        end

      {:error, reason} ->
        {:error, {:model_policy_failed, attempts, reason}}
    end
  end

  defp handle_model_failure(reason, model, rest, call, model_attempt, attempts) do
    case failure_class(call.policy.classify, reason) do
      {:ok, failure_class} ->
        attempts =
          attempts ++ [attempt(model, attempts, model_attempt, :error, failure_class, reason)]

        continue_after_failure(failure_class, model, rest, call, model_attempt, attempts)

      {:error, classify_reason} ->
        attempts = attempts ++ [attempt(model, attempts, model_attempt, :error, :permanent, reason)]
        {:error, {:model_policy_failed, attempts, classify_reason}}
    end
  end

  defp continue_after_failure(:transient, model, rest, call, model_attempt, attempts)
       when model_attempt < call.policy.retry.max_attempts do
    case sleep(call.policy, model_attempt) do
      :ok -> call_model(model, rest, call, model_attempt + 1, attempts)
      {:error, reason} -> {:error, {:model_policy_failed, attempts, reason}}
    end
  end

  defp continue_after_failure(_failure_class, _model, rest, call, _model_attempt, attempts),
    do: call_models(rest, call, attempts)

  defp safe_capability_call(llm, intent, journal, context) do
    case llm.(intent, journal, context) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_capability_result, other}}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp failure_class(nil, reason), do: {:ok, classify(reason)}

  defp failure_class(classify, reason) when is_function(classify, 1),
    do: safe_failure_class(fn -> classify.(reason) end)

  defp failure_class(classify, reason) when is_atom(classify),
    do: safe_failure_class(fn -> classify.classify(reason) end)

  defp safe_failure_class(callback) do
    case safe_callback(callback, :model_classifier_failed) do
      {:ok, class} when class in @failure_classes -> {:ok, class}
      {:ok, class} -> {:error, {:invalid_model_failure_class, class}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_callback(callback, error_tag) do
    case callback.() do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {error_tag, reason}}
      value -> {:ok, value}
    end
  rescue
    exception -> {:error, {error_tag, exception}}
  catch
    kind, reason -> {:error, {error_tag, {kind, reason}}}
  end

  defp route_intent(%Effect.Intent{} = intent, %LLMDB.Model{} = model) do
    model_ref = Config.model_ref(model)
    prompt = intent.payload |> Schema.get_key(:prompt, %{}) |> Map.put(:model, model_ref)
    payload = intent.payload |> Map.put(:model, model) |> Map.put(:prompt, prompt)
    %Effect.Intent{intent | payload: payload}
  end

  defp attach_metadata(%Effect.LLMDecision{} = output, model, attempts) do
    metadata = Map.merge(output.metadata, policy_metadata(model, attempts))
    %Effect.LLMDecision{output | metadata: metadata}
  end

  defp attach_metadata(%{} = output, model, attempts) do
    metadata =
      case Schema.get_key(output, :metadata, %{}) do
        metadata when is_map(metadata) -> metadata
        _metadata -> %{}
      end

    output
    |> Map.delete("metadata")
    |> Map.put(:metadata, Map.merge(metadata, policy_metadata(model, attempts)))
  end

  defp attach_metadata(output, _model, _attempts), do: output

  defp policy_metadata(model, attempts) do
    %{
      model: Config.model_ref(model),
      provider: model.provider,
      model_attempts: attempts
    }
  end

  defp attempt(model, attempts, model_attempt, :ok, _failure_class) do
    %{
      attempt: length(attempts) + 1,
      model_attempt: model_attempt,
      provider: model.provider,
      model: Config.model_ref(model),
      status: :ok,
      winner: true
    }
  end

  defp attempt(model, attempts, model_attempt, :error, failure_class, reason) do
    %{
      attempt: length(attempts) + 1,
      model_attempt: model_attempt,
      provider: model.provider,
      model: Config.model_ref(model),
      status: :error,
      failure_class: failure_class,
      failure: failure_name(reason)
    }
  end

  defp failure_name(reason) when is_atom(reason), do: reason
  defp failure_name({reason, _detail}) when is_atom(reason), do: reason
  defp failure_name(%module{}), do: inspect(module)
  defp failure_name(_reason), do: :unknown

  defp sleep(%__MODULE__{retry: %{backoff: backoff}, sleep: sleep}, attempt) do
    delay =
      case backoff.type do
        :exponential -> round(backoff.min * :math.pow(2, attempt - 1))
        :fixed -> backoff.min
      end

    case safe_callback(fn -> sleep.(cap_backoff(delay, backoff.max)) end, :model_backoff_failed) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp cap_backoff(delay, max) when max > 0, do: min(delay, max)
  defp cap_backoff(delay, _max), do: delay

  defp normalize_models(models) when is_list(models) do
    Enum.reduce_while(models, {:ok, []}, fn model, {:ok, normalized} ->
      case Config.normalize_model_spec(model) do
        {:ok, model} -> {:cont, {:ok, [model | normalized]}}
        {:error, reason} -> {:halt, {:error, {:invalid_model_policy_model, reason}}}
      end
    end)
    |> case do
      {:ok, models} -> {:ok, Enum.reverse(models)}
      error -> error
    end
  end

  defp normalize_models(models), do: {:error, {:invalid_model_policy_models, models}}

  defp normalize_selection(models) when is_list(models), do: normalize_models(models)
  defp normalize_selection(model), do: normalize_models([model])

  defp require_models([]), do: {:error, :empty_model_policy_models}
  defp require_models(_models), do: :ok

  defp normalize_callback(nil, _name, _arity), do: {:ok, nil}

  defp normalize_callback(callback, _name, arity) when is_function(callback, arity),
    do: {:ok, callback}

  defp normalize_callback(callback, name, arity) when is_atom(callback) do
    if Code.ensure_loaded?(callback) and function_exported?(callback, name, arity) do
      {:ok, callback}
    else
      {:error, {:invalid_model_policy_callback, name, callback}}
    end
  end

  defp normalize_callback(callback, name, _arity),
    do: {:error, {:invalid_model_policy_callback, name, callback}}

  defp normalize_retry(nil), do: RetryPolicy.new(%{})

  defp normalize_retry(retry) do
    case RetryPolicy.new(retry) do
      {:ok, retry} -> {:ok, retry}
      {:error, reason} -> {:error, {:invalid_model_policy_retry, reason}}
    end
  end

  defp normalize_sleep(nil), do: {:ok, &Process.sleep/1}
  defp normalize_sleep(sleep) when is_function(sleep, 1), do: {:ok, sleep}
  defp normalize_sleep(sleep), do: {:error, {:invalid_model_policy_sleep, sleep}}
end
