defmodule Jidoka.CodingPack.VerifyPort do
  @moduledoc "Trusted named verification-helper registry backed by a constrained shell port."

  alias Jidoka.CodingPack.{Error, Glob, ShellPort}

  @keys [:description, :command, :args, :targets, :timeout_ms, :network, :exit_codes]

  @enforce_keys [:shell, :helpers]
  defstruct [:shell, :helpers]

  @type t :: %__MODULE__{shell: ShellPort.t(), helpers: map()}

  @doc "Builds verification helpers from trusted host configuration."
  @spec new(ShellPort.t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%ShellPort{} = shell, helpers) when is_map(helpers) do
    with {:ok, helpers} <- normalize_helpers(helpers) do
      {:ok, %__MODULE__{shell: shell, helpers: helpers}}
    end
  end

  def new(%ShellPort{}, _helpers), do: {:error, Error.new(:coding_verify_registration_invalid)}

  @doc false
  def fetch(%__MODULE__{helpers: helpers}, id) do
    case Map.fetch(helpers, id) do
      {:ok, helper} -> {:ok, helper}
      :error -> {:error, Error.new(:coding_verify_helper_unknown, %{helper_id: id})}
    end
  end

  defp normalize_helpers(helpers) do
    Enum.reduce_while(helpers, {:ok, %{}}, fn {id, attrs}, {:ok, normalized} ->
      case normalize_helper(id, attrs) do
        {:ok, helper} -> {:cont, {:ok, Map.put(normalized, id, helper)}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_helper(id, attrs)
       when is_binary(id) and id != "" and (is_map(attrs) or is_list(attrs)) do
    attrs = Jidoka.Schema.normalize_attrs(attrs)
    unknown = Map.keys(attrs) -- @keys
    description = Map.get(attrs, :description)
    command = Map.get(attrs, :command)
    args = Map.get(attrs, :args, [])
    targets = Map.get(attrs, :targets, [])
    timeout = Map.get(attrs, :timeout_ms, 60_000)
    network = Map.get(attrs, :network, false)
    exit_codes = Map.get(attrs, :exit_codes, [0])

    with [] <- unknown,
         true <- text?(description),
         true <- text?(command),
         true <- string_list?(args),
         true <- string_list?(targets),
         {:ok, target_patterns} <- compile_targets(targets),
         true <- is_integer(timeout) and timeout > 0,
         true <- is_boolean(network),
         true <- valid_exit_codes?(exit_codes) do
      {:ok,
       %{
         id: id,
         description: description,
         command: command,
         args: args,
         targets: targets,
         target_patterns: target_patterns,
         target_required: "{target}" in args,
         timeout_ms: timeout,
         network: network,
         exit_codes: Enum.uniq(exit_codes)
       }}
    else
      _reason -> {:error, Error.new(:coding_verify_registration_invalid, %{helper_id: id})}
    end
  end

  defp normalize_helper(id, _attrs),
    do: {:error, Error.new(:coding_verify_registration_invalid, %{helper_id: inspect(id)})}

  defp compile_targets(targets) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, patterns} ->
      case Glob.compile(target) do
        {:ok, pattern} -> {:cont, {:ok, [pattern | patterns]}}
        {:error, _error} -> {:halt, {:error, :invalid_target_pattern}}
      end
    end)
    |> case do
      {:ok, patterns} -> {:ok, Enum.reverse(patterns)}
      error -> error
    end
  end

  defp text?(value),
    do: is_binary(value) and value != "" and String.valid?(value) and not String.contains?(value, <<0>>)

  defp string_list?(values), do: is_list(values) and Enum.all?(values, &text?/1)

  defp valid_exit_codes?(values),
    do: is_list(values) and values != [] and Enum.all?(values, &(is_integer(&1) and &1 >= 0 and &1 <= 255))
end
