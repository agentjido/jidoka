defmodule Jidoka.Workflow.Dsl.Helpers do
  @moduledoc false

  # Spark receives the outer DSL keyword list before nested ref helpers run.
  # Public `input:` stays ergonomic while the internal entity stores it as
  # `params:` to avoid colliding with imported `input/1` refs.
  defmacro map(name, opts) do
    opts = rewrite_option(opts, :input, :params)

    quote do
      map_step(unquote(name), unquote(opts))
    end
  end

  defmacro reduce(name, opts) do
    opts = rewrite_option(opts, :input, :params)

    quote do
      reduce_step(unquote(name), unquote(opts))
    end
  end

  defp rewrite_option(opts, from, to) when is_list(opts) do
    Enum.map(opts, fn
      {^from, value} -> {to, value}
      other -> other
    end)
  end

  defp rewrite_option(opts, _from, _to), do: opts
end
