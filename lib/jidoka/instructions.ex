defmodule Jidoka.Instructions do
  @moduledoc """
  Resolves instructions for one agent request.

  Agent specifications keep stable, data-only instructions. A caller can pass
  `instructions:` at run time to replace them for one request. The value can be
  a non-empty string, a two-argument function, or a module that implements this
  behaviour.

  A provider receives the base instructions and a public `Jidoka.Context`. The
  context contains request data and metadata. It does not contain trusted
  runtime data or internal request objects.
  """

  alias Jidoka.Context
  alias Jidoka.Turn

  @type result :: String.t() | {:ok, String.t()} | {:error, term()}
  @type provider :: String.t() | (String.t(), Context.t() -> result()) | module()

  @callback resolve(base_instructions :: String.t(), context :: Context.t()) :: result()

  @doc false
  @spec resolve(Turn.Plan.t(), Turn.Request.t(), keyword()) ::
          {:ok, Turn.Plan.t()} | {:error, term()}
  def resolve(%Turn.Plan{} = plan, %Turn.Request{} = request, opts) when is_list(opts) do
    case Keyword.fetch(opts, :instructions) do
      :error ->
        {:ok, plan}

      {:ok, provider} ->
        with {:ok, context} <- public_context(plan, request),
             {:ok, instructions} <- resolve_provider(provider, plan.spec.instructions, context) do
          spec = %{plan.spec | instructions: instructions}
          {:ok, %{plan | spec: spec}}
        end
    end
  end

  defp public_context(%Turn.Plan{} = plan, %Turn.Request{} = request) do
    Context.new(
      agent_id: plan.spec.id,
      request_id: request.request_id,
      input: request.input,
      data: Context.data(request.context),
      metadata: request.context.metadata,
      request_metadata: request.metadata
    )
  end

  defp resolve_provider(instructions, _base, _context) when is_binary(instructions),
    do: validate(instructions)

  defp resolve_provider(provider, base, context) when is_function(provider, 2),
    do: call_provider(fn -> provider.(base, context) end)

  defp resolve_provider(provider, base, context) when is_atom(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :resolve, 2) do
      call_provider(fn -> provider.resolve(base, context) end)
    else
      {:error, {:invalid_instruction_provider, provider}}
    end
  end

  defp resolve_provider(provider, _base, _context),
    do: {:error, {:invalid_instruction_provider, provider}}

  defp call_provider(callback) do
    case callback.() do
      {:ok, instructions} -> validate(instructions)
      {:error, reason} -> {:error, {:instruction_provider_failed, reason}}
      instructions -> validate(instructions)
    end
  rescue
    exception -> {:error, {:instruction_provider_failed, exception}}
  catch
    kind, reason -> {:error, {:instruction_provider_failed, {kind, reason}}}
  end

  defp validate(instructions) when is_binary(instructions) do
    if String.trim(instructions) == "" do
      {:error, {:invalid_dynamic_instructions, instructions}}
    else
      {:ok, instructions}
    end
  end

  defp validate(instructions), do: {:error, {:invalid_dynamic_instructions, instructions}}
end
