defmodule Jidoka.Agent.Compiler.Resolver do
  @moduledoc false

  alias Jidoka.Agent.Compiler.Context

  @type dsl_path :: [atom()]

  @callback name() :: atom()
  @callback dsl_paths() :: [dsl_path()]
  @callback resolve(Context.t()) :: {:ok, Context.t()} | {:error, term()} | Context.t()

  @optional_callbacks dsl_paths: 0

  @spec name(module()) :: atom()
  def name(resolver) when is_atom(resolver) do
    if function_exported?(resolver, :name, 0), do: resolver.name(), else: resolver
  end

  @spec dsl_paths(module()) :: [dsl_path()]
  def dsl_paths(resolver) when is_atom(resolver) do
    if function_exported?(resolver, :dsl_paths, 0), do: resolver.dsl_paths(), else: []
  end

  @spec run([module()], Context.t()) :: {:ok, Context.t()} | {:error, {module(), term()}}
  def run(resolvers, %Context{} = context) when is_list(resolvers) do
    Enum.reduce_while(resolvers, {:ok, context}, fn resolver, {:ok, context} ->
      case resolver.resolve(context) do
        {:ok, %Context{} = context} -> {:cont, {:ok, context}}
        %Context{} = context -> {:cont, {:ok, context}}
        {:error, reason} -> {:halt, {:error, {resolver, reason}}}
        other -> {:halt, {:error, {resolver, {:invalid_resolver_result, other}}}}
      end
    end)
  end
end
