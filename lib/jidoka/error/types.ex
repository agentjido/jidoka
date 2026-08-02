defmodule Jidoka.Error.ValidationError do
  @moduledoc "Invalid input or schema validation error."
  use Splode.Error, class: :invalid, fields: [:message, :field, :value, :details]

  @impl true
  def exception(opts) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    opts
    |> Keyword.put_new(:message, "Invalid Jidoka input")
    |> Keyword.put_new(:details, %{})
    |> super()
  end
end

defmodule Jidoka.Error.ConfigError do
  @moduledoc "Invalid Jidoka configuration error."
  use Splode.Error, class: :config, fields: [:message, :field, :value, :details]

  @impl true
  def exception(opts) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    opts
    |> Keyword.put_new(:message, "Invalid Jidoka configuration")
    |> Keyword.put_new(:details, %{})
    |> super()
  end
end

defmodule Jidoka.Error.ExecutionError do
  @moduledoc "Jidoka runtime execution error."
  use Splode.Error, class: :execution, fields: [:message, :phase, :details]

  @impl true
  def exception(opts) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    opts
    |> Keyword.put_new(:message, "Jidoka execution failed")
    |> Keyword.put_new(:details, %{})
    |> super()
  end
end
