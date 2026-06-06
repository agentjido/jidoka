defmodule Jidoka.Error do
  @moduledoc """
  Splode-backed error helpers for Jidoka.

  Runtime-facing APIs should return these errors instead of leaking raw atoms,
  tuples, or third-party exception structs. Lower-level constructors may still
  return library-native validation details when that is the precise contract.
  """

  defmodule Invalid do
    @moduledoc "Invalid input error class for Splode."
    use Splode.ErrorClass, class: :invalid
  end

  defmodule Execution do
    @moduledoc "Runtime execution error class for Splode."
    use Splode.ErrorClass, class: :execution
  end

  defmodule Config do
    @moduledoc "Configuration error class for Splode."
    use Splode.ErrorClass, class: :config
  end

  defmodule Internal do
    @moduledoc "Internal error class for Splode."
    use Splode.ErrorClass, class: :internal

    defmodule UnknownError do
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
  end

  use Splode,
    error_classes: [
      invalid: Invalid,
      execution: Execution,
      config: Config,
      internal: Internal
    ],
    unknown_error: Internal.UnknownError

  defmodule ValidationError do
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

  defmodule ConfigError do
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

  defmodule ExecutionError do
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

  @type category :: :validation | :configuration | :execution | :internal | :unknown
  @type context :: keyword() | map()

  @doc "Builds a Splode-backed validation error."
  @spec validation_error(String.t(), keyword() | map()) :: Exception.t()
  def validation_error(message, details \\ %{}) do
    ValidationError.exception(error_opts(details, message))
  end

  @doc "Builds a Splode-backed configuration error."
  @spec config_error(String.t(), keyword() | map()) :: Exception.t()
  def config_error(message, details \\ %{}) do
    ConfigError.exception(error_opts(details, message))
  end

  @doc "Builds a Splode-backed execution error."
  @spec execution_error(String.t(), keyword() | map()) :: Exception.t()
  def execution_error(message, details \\ %{}) do
    ExecutionError.exception(error_opts(details, message))
  end

  @doc """
  Normalizes arbitrary error terms into a Jidoka/Splode exception.
  """
  @spec normalize(term(), context()) :: Exception.t()
  def normalize(reason, context \\ %{}), do: Jidoka.Error.Normalize.normalize(reason, context)

  @doc "Returns the Jidoka error category for a normalized exception or aggregate error."
  @spec category(term()) :: category()
  def category(error), do: Jidoka.Error.Format.category(error)

  @doc "Returns whether an error term is already a Jidoka/Splode error."
  @spec normalized?(term()) :: boolean()
  def normalized?(error), do: category(error) != :unknown

  @doc "Converts a Jidoka/Splode error into a serializable map."
  @spec to_map(term()) :: map()
  def to_map(error), do: Jidoka.Error.Format.to_map(error)

  @doc "Formats a Jidoka/Splode error into a short human-readable message."
  @spec format(term()) :: String.t()
  def format(error), do: Jidoka.Error.Format.format(error)

  defp error_opts(details, message) when is_map(details) do
    details
    |> Map.put(:message, message)
    |> Map.put_new(:details, %{})
  end

  defp error_opts(details, message) when is_list(details) do
    details
    |> Keyword.put(:message, message)
    |> Keyword.put_new(:details, %{})
  end
end
