defmodule Jidoka.Extension.Protocol.Session do
  @moduledoc "Pure protocol-v1 correlation and negotiation state."

  @enforce_keys [:binding]
  defstruct binding: nil,
            initialized?: false,
            closed?: false,
            pending: MapSet.new(),
            sent_ids: MapSet.new(),
            capabilities: MapSet.new(),
            permissions: MapSet.new()

  @type t :: %__MODULE__{
          binding: Jidoka.Extension.Binding.t(),
          initialized?: boolean(),
          closed?: boolean(),
          pending: MapSet.t(),
          sent_ids: MapSet.t(),
          capabilities: MapSet.t(),
          permissions: MapSet.t()
        }
end

defmodule Jidoka.Extension.Protocol do
  @moduledoc "Bounded JSON-RPC 2.0 protocol-v1 data contract for process extensions."

  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Extension.Binding
  alias Jidoka.Extension.Protocol.Session

  @protocol_version 1
  @max_line_bytes 1_048_576
  @methods %{
    "initialize" => nil,
    "health" => nil,
    "tool.list" => "tools",
    "tool.call" => "tools",
    "command.list" => "tools",
    "command.call" => "tools",
    "provider.list" => "providers",
    "provider.start" => "providers",
    "provider.update" => "providers",
    "provider.cancel" => "providers",
    "policy.advise" => "policy_advice",
    "context.contribute" => "context",
    "lifecycle.notify" => nil,
    "state.restore" => "state",
    "state.checkpoint" => "state",
    "result.update" => "results",
    "ui_data.update" => "ui_data",
    "request.cancel" => nil,
    "shutdown" => nil
  }
  @notifications ~w(lifecycle.notify provider.update result.update ui_data.update request.cancel)

  @doc "Returns the wire protocol version."
  @spec version() :: pos_integer()
  def version, do: @protocol_version

  @doc "Returns the fixed protocol-v1 method catalog."
  @spec methods() :: [String.t()]
  def methods, do: Map.keys(@methods) |> Enum.sort()

  @doc "Starts pure correlation state for one resolved binding."
  @spec new(Binding.t()) :: Session.t()
  def new(%Binding{} = binding), do: %Session{binding: binding}

  @doc "Builds the required initialize request and records its correlation ID."
  @spec initialize(Session.t(), String.t(), :interactive | :automation) ::
          {:ok, binary(), Session.t()} | {:error, term()}
  def initialize(%Session{initialized?: false} = session, id, mode) do
    binding = session.binding

    params = %{
      "protocol_version" => @protocol_version,
      "extension_id" => binding.request_id,
      "identity_hash" => binding.identity.content_hash,
      "mode" => Atom.to_string(mode),
      "requested_permissions" => binding.permissions.values,
      "granted_permissions" => binding.permissions.values,
      "capabilities" => binding.capabilities.values
    }

    request(session, id, "initialize", params)
  end

  def initialize(%Session{}, _id, _mode), do: {:error, :protocol_already_initialized}

  @doc "Validates initialize evidence and enables negotiated capabilities."
  @spec complete_initialize(Session.t(), map()) :: {:ok, Session.t()} | {:error, term()}
  def complete_initialize(%Session{} = session, result) when is_map(result) do
    binding = session.binding
    capabilities = get(result, "capabilities", [])
    permissions = get(result, "granted_permissions", [])

    with @protocol_version <- get(result, "protocol_version"),
         true <- get(result, "extension_id") == binding.request_id,
         true <- get(result, "identity_hash") == binding.identity.content_hash,
         true <- MapSet.subset?(MapSet.new(capabilities), MapSet.new(binding.capabilities.values)),
         true <- MapSet.new(permissions) == MapSet.new(binding.permissions.values) do
      {:ok,
       %{
         session
         | initialized?: true,
           capabilities: MapSet.new(capabilities),
           permissions: MapSet.new(permissions)
       }}
    else
      reason -> {:error, {:protocol_initialize_mismatch, reason}}
    end
  end

  @doc "Encodes one correlated request as one complete JSONL frame."
  @spec request(Session.t(), String.t(), String.t(), map()) ::
          {:ok, binary(), Session.t()} | {:error, term()}
  def request(%Session{} = session, id, method, params) do
    with :ok <- request_state(session, method),
         :ok <- valid_id(id),
         false <- MapSet.member?(session.sent_ids, id),
         :ok <- validate_method(session, method, params),
         {:ok, frame} <- encode(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}) do
      next = %{session | pending: MapSet.put(session.pending, id), sent_ids: MapSet.put(session.sent_ids, id)}
      {:ok, frame, next}
    else
      true -> {:error, {:duplicate_protocol_id, id}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Encodes one allowed notification."
  @spec notification(Session.t(), String.t(), map()) :: {:ok, binary()} | {:error, term()}
  def notification(%Session{} = session, method, params) do
    with true <- method in @notifications,
         :ok <- request_state(session, method),
         :ok <- validate_method(session, method, params) do
      encode(%{"jsonrpc" => "2.0", "method" => method, "params" => params})
    else
      false -> {:error, {:protocol_notification_forbidden, method}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Encodes a success response."
  @spec response(String.t() | integer(), term()) :: {:ok, binary()} | {:error, term()}
  def response(id, result), do: encode(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  @doc "Encodes a JSON-RPC error response."
  @spec error_response(String.t() | integer() | nil, integer(), String.t(), map()) ::
          {:ok, binary()} | {:error, term()}
  def error_response(id, code, message, data \\ %{}) when is_integer(code) and is_binary(message) do
    encode(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message, "data" => data}})
  end

  @doc "Decodes one response or child notification and updates correlation state."
  @spec receive_line(Session.t(), binary()) :: {:ok, map(), Session.t()} | {:error, term()}
  def receive_line(%Session{} = session, line) do
    with {:ok, message} <- decode(line),
         {:ok, next} <- correlate(session, message) do
      {:ok, message, next}
    end
  end

  @doc "Marks one pending request as timed out. Late responses then fail as unsolicited."
  @spec timeout(Session.t(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def timeout(%Session{} = session, id) do
    if MapSet.member?(session.pending, id),
      do: {:ok, %{session | pending: MapSet.delete(session.pending, id)}},
      else: {:error, {:unknown_protocol_request, id}}
  end

  @doc "Marks the protocol closed after a shutdown acknowledgment."
  @spec close(Session.t()) :: Session.t()
  def close(%Session{} = session), do: %{session | closed?: true, pending: MapSet.new()}

  @doc "Encodes exactly one bounded JSON object and one newline."
  @spec encode(map()) :: {:ok, binary()} | {:error, term()}
  def encode(message) when is_map(message) do
    with :ok <- Contract.validate_safe_map(message),
         {:ok, json} <- Jason.encode(message),
         true <- byte_size(json) + 1 <= @max_line_bytes do
      {:ok, json <> "\n"}
    else
      false -> {:error, :protocol_frame_too_large}
      {:error, reason} -> {:error, {:invalid_protocol_frame, reason}}
    end
  end

  @doc "Decodes exactly one bounded UTF-8 JSON object line."
  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(line) when is_binary(line) do
    with true <- String.valid?(line),
         true <- byte_size(line) <= @max_line_bytes,
         :ok <- one_line(line),
         {:ok, message} when is_map(message) <- Jason.decode(String.trim_trailing(line, "\n")),
         "2.0" <- get(message, "jsonrpc"),
         :ok <- Contract.validate_safe_map(message),
         :ok <- valid_message_shape(message) do
      {:ok, message}
    else
      false -> {:error, :invalid_protocol_line}
      {:error, reason} -> {:error, {:invalid_protocol_line, reason}}
      _other -> {:error, :invalid_protocol_message}
    end
  end

  def decode(_line), do: {:error, :invalid_protocol_line}

  defp request_state(%Session{closed?: true}, _method), do: {:error, :protocol_closed}
  defp request_state(%Session{initialized?: false}, "initialize"), do: :ok
  defp request_state(%Session{initialized?: false}, _method), do: {:error, :protocol_not_initialized}
  defp request_state(%Session{initialized?: true}, "initialize"), do: {:error, :protocol_already_initialized}
  defp request_state(%Session{}, _method), do: :ok

  defp validate_method(session, method, params) do
    with {:ok, permission} <- Map.fetch(@methods, method),
         true <- is_map(params),
         :ok <- Contract.validate_safe_map(params),
         :ok <- permission_granted(session, permission),
         :ok <- capability_declared(session, method),
         :ok <- validate_params(method, params) do
      :ok
    else
      :error -> {:error, {:unknown_protocol_method, method}}
      false -> {:error, {:invalid_protocol_params, method}}
      {:error, _reason} = error -> error
    end
  end

  defp permission_granted(_session, nil), do: :ok

  defp permission_granted(session, permission) do
    if MapSet.member?(session.permissions, permission),
      do: :ok,
      else: {:error, {:protocol_permission_not_granted, permission}}
  end

  defp capability_declared(_session, method) when method in ["initialize", "health", "shutdown", "request.cancel"],
    do: :ok

  defp capability_declared(session, method) do
    capability = "protocol." <> (method |> String.split(".") |> hd())

    if MapSet.member?(session.capabilities, capability),
      do: :ok,
      else: {:error, {:protocol_capability_not_declared, capability}}
  end

  defp validate_params("initialize", params),
    do:
      require_keys(
        params,
        ~w(protocol_version extension_id identity_hash mode requested_permissions granted_permissions capabilities)
      )

  defp validate_params(method, params) when method in ["tool.call", "command.call"], do: require_keys(params, ~w(name))
  defp validate_params("provider.start", params), do: require_keys(params, ~w(provider request))

  defp validate_params(method, params) when method in ["provider.update", "provider.cancel"],
    do: require_keys(params, ~w(correlation_id))

  defp validate_params("lifecycle.notify", params), do: require_keys(params, ~w(event))
  defp validate_params("state.restore", params), do: require_keys(params, ~w(state))

  defp validate_params(method, params) when method in ["result.update", "ui_data.update"],
    do: require_keys(params, ~w(namespace data))

  defp validate_params("request.cancel", params), do: require_keys(params, ~w(id))
  defp validate_params(_method, _params), do: :ok

  defp require_keys(params, keys) do
    missing = Enum.reject(keys, &Map.has_key?(params, &1))
    if missing == [], do: :ok, else: {:error, {:missing_protocol_params, missing}}
  end

  defp correlate(session, %{"id" => id} = message) when is_map_key(message, "result") or is_map_key(message, "error") do
    if MapSet.member?(session.pending, id),
      do: {:ok, %{session | pending: MapSet.delete(session.pending, id)}},
      else: {:error, {:unsolicited_protocol_response, id}}
  end

  defp correlate(session, %{"method" => method, "params" => params}) do
    with true <- method in @notifications,
         :ok <- validate_method(session, method, params) do
      {:ok, session}
    else
      false -> {:error, {:unsolicited_protocol_method, method}}
      {:error, _reason} = error -> error
    end
  end

  defp correlate(_session, _message), do: {:error, :invalid_protocol_message}

  defp valid_message_shape(%{"id" => _id, "result" => _result} = message) do
    if Map.has_key?(message, "error") or Map.has_key?(message, "method"),
      do: {:error, :ambiguous_protocol_message},
      else: :ok
  end

  defp valid_message_shape(%{"id" => _id, "error" => %{"code" => code, "message" => message}} = value)
       when is_integer(code) and is_binary(message) do
    if Map.has_key?(value, "result") or Map.has_key?(value, "method"),
      do: {:error, :ambiguous_protocol_message},
      else: :ok
  end

  defp valid_message_shape(%{"method" => method, "params" => params}) when is_binary(method) and is_map(params), do: :ok
  defp valid_message_shape(_message), do: {:error, :invalid_protocol_message_shape}

  defp valid_id(id) when is_binary(id) and id != "", do: :ok
  defp valid_id(id) when is_integer(id), do: :ok
  defp valid_id(id), do: {:error, {:invalid_protocol_id, id}}

  defp one_line(line) do
    content = String.trim_trailing(line, "\n")
    if String.contains?(content, ["\n", "\r"]), do: {:error, :protocol_noise}, else: :ok
  end

  defp get(map, key, default \\ nil), do: Map.get(map, key, default)
end
