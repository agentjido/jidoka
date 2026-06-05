defmodule Jidoka.Config do
  @moduledoc """
  Runtime configuration helpers for Jidoka.
  """

  alias Jidoka.Agent.Spec.Generation

  @default_model "openai:gpt-4o-mini"
  @default_generation %{params: %{temperature: 0.0, max_tokens: 500}}
  @default_max_model_turns 8
  @default_turn_timeout_ms 30_000
  @default_max_parallel_operations 4

  @type model_spec :: ReqLLM.model_input()
  @type model :: LLMDB.Model.t()

  @doc """
  Returns the configured default model as normalized LLMDB data.
  """
  @spec default_model() :: model()
  def default_model do
    :jidoka
    |> Application.get_env(:default_model, @default_model)
    |> normalize_model_spec!(:default_model)
  end

  @doc """
  Returns the configured default generation parameters.
  """
  @spec default_generation() :: Generation.t()
  def default_generation do
    :jidoka
    |> Application.get_env(:default_generation, @default_generation)
    |> normalize_generation!(:default_generation)
  end

  @doc """
  Returns the globally configured default maximum model turns.
  """
  @spec default_max_model_turns() :: pos_integer()
  def default_max_model_turns do
    :jidoka
    |> Application.get_env(:default_max_model_turns, @default_max_model_turns)
    |> normalize_positive_integer!(:default_max_model_turns)
  end

  @doc """
  Returns the globally configured default turn timeout in milliseconds.
  """
  @spec default_turn_timeout_ms() :: pos_integer()
  def default_turn_timeout_ms do
    :jidoka
    |> Application.get_env(:default_turn_timeout_ms, @default_turn_timeout_ms)
    |> normalize_positive_integer!(:default_turn_timeout_ms)
  end

  @doc """
  Returns the default concurrency bound for operation batches planned by one
  model turn.
  """
  @spec default_max_parallel_operations() :: pos_integer()
  def default_max_parallel_operations do
    :jidoka
    |> Application.get_env(:default_max_parallel_operations, @default_max_parallel_operations)
    |> normalize_positive_integer!(:default_max_parallel_operations)
  end

  @doc """
  Validates and normalizes any ReqLLM-supported model input.
  """
  @spec normalize_model_spec(term(), atom()) :: {:ok, model()} | {:error, term()}
  def normalize_model_spec(value, field \\ :model)

  def normalize_model_spec(value, field) when is_binary(value) do
    value
    |> normalize_model_string()
    |> normalize_model_with_req_llm(field)
  end

  def normalize_model_spec(value, field) do
    normalize_model_with_req_llm(value, field)
  end

  defp normalize_model_with_req_llm(value, field) do
    case ReqLLM.model(value) do
      {:ok, %LLMDB.Model{} = model} -> {:ok, model}
      {:error, reason} -> {:error, {field, value, reason}}
    end
  rescue
    exception -> {:error, {field, value, Exception.message(exception)}}
  end

  defp normalize_model_string(value) do
    value = String.trim(value)

    case String.split(value, ":", parts: 2) do
      [provider, id] when provider != "" and id != "" ->
        %{provider: provider, id: id}

      _other ->
        value
    end
  end

  @doc """
  Validates and normalizes a model input, raising on error.
  """
  @spec normalize_model_spec!(term(), atom()) :: model()
  def normalize_model_spec!(value, field \\ :model) do
    case normalize_model_spec(value, field) do
      {:ok, model} -> model
      {:error, reason} -> raise ArgumentError, "invalid #{field}: #{inspect(reason)}"
    end
  end

  @doc """
  Validates and normalizes generation defaults.
  """
  @spec normalize_generation(term(), atom()) :: {:ok, Generation.t()} | {:error, term()}
  def normalize_generation(value, field \\ :generation) do
    case Generation.from_input(value) do
      {:ok, %Generation{} = generation} -> {:ok, generation}
      {:error, reason} -> {:error, {field, value, reason}}
    end
  end

  @doc """
  Validates and normalizes generation defaults, raising on error.
  """
  @spec normalize_generation!(term(), atom()) :: Generation.t()
  def normalize_generation!(value, field \\ :generation) do
    case normalize_generation(value, field) do
      {:ok, generation} -> generation
      {:error, reason} -> raise ArgumentError, "invalid #{field}: #{inspect(reason)}"
    end
  end

  @doc """
  Validates and normalizes a positive integer config value.
  """
  @spec normalize_positive_integer(term(), atom()) :: {:ok, pos_integer()} | {:error, term()}
  def normalize_positive_integer(value, _field) when is_integer(value) and value > 0,
    do: {:ok, value}

  def normalize_positive_integer(value, field) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, {field, value, :not_positive_integer}}
    end
  end

  def normalize_positive_integer(value, field),
    do: {:error, {field, value, :not_positive_integer}}

  @doc """
  Validates and normalizes a positive integer config value, raising on error.
  """
  @spec normalize_positive_integer!(term(), atom()) :: pos_integer()
  def normalize_positive_integer!(value, field) do
    case normalize_positive_integer(value, field) do
      {:ok, integer} -> integer
      {:error, reason} -> raise ArgumentError, "invalid #{field}: #{inspect(reason)}"
    end
  end

  @doc """
  Returns a compact provider/model identifier for prompts, traces, and tests.
  """
  @spec model_ref(model()) :: String.t()
  def model_ref(%LLMDB.Model{} = model) do
    provider = Atom.to_string(model.provider)
    model_id = model.provider_model_id || model.model || model.id

    provider <> ":" <> model_id
  end

  def model_ref(model_input) do
    model_input
    |> normalize_model_spec!()
    |> model_ref()
  end
end
