defmodule Jidoka.Error.Invalid do
  @moduledoc "Invalid input error class for Splode."
  use Splode.ErrorClass, class: :invalid
end

defmodule Jidoka.Error.Execution do
  @moduledoc "Runtime execution error class for Splode."
  use Splode.ErrorClass, class: :execution
end

defmodule Jidoka.Error.Config do
  @moduledoc "Configuration error class for Splode."
  use Splode.ErrorClass, class: :config
end

defmodule Jidoka.Error.Internal do
  @moduledoc "Internal error class for Splode."
  use Splode.ErrorClass, class: :internal
end

defmodule Jidoka.Error.Internal.UnknownError do
  @moduledoc false
  use Splode.Error, class: :internal, fields: [:message, :details, :error]

  @impl true
  def exception(opts) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts
    message = Keyword.get(opts, :message) || unknown_message(opts[:error])

    opts
    |> Keyword.put(:message, message)
    |> Keyword.put_new(:details, %{})
    |> super()
  end

  defp unknown_message(nil), do: "Unknown Jidoka error"
  defp unknown_message(message) when is_binary(message), do: message
  defp unknown_message(error), do: inspect(error)
end
