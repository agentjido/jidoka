defmodule Jidoka.Sanitize do
  @moduledoc false

  @default_preview_bytes 500
  @key_assignment_pattern ~r/\b(api[_-]?key|apikey|auth[_-]?token|authtoken|authorization|bearer|client[_-]?secret|clientsecret|password|private[_-]?key|privatekey|secret|token)\b\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;]+)/i
  @token_pattern ~r/\b(?:sk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}|[A-Za-z0-9_\-]{24,}\.[A-Za-z0-9_\-]{12,}\.[A-Za-z0-9_\-]{12,})\b/
  @large_keys MapSet.new([
                "arguments",
                "context",
                "data",
                "llm_opts",
                "messages",
                "prompt",
                "query",
                "raw",
                "raw_request",
                "raw_response",
                "request",
                "request_opts",
                "response",
                "result",
                "stacktrace",
                "state"
              ])

  @sensitive_exact MapSet.new([
                     "api_key",
                     "apikey",
                     "password",
                     "secret",
                     "token",
                     "auth_token",
                     "authtoken",
                     "private_key",
                     "privatekey",
                     "access_key",
                     "accesskey",
                     "bearer",
                     "api_secret",
                     "apisecret",
                     "client_secret",
                     "clientsecret"
                   ])
  @sensitive_contains ["secret_"]
  @sensitive_suffixes ["_secret", "_key", "_token", "_password"]

  @doc false
  @spec payload(term()) :: term()
  def payload(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> payload()
    |> Map.put(:__struct__, inspect(struct.__struct__))
  end

  def payload(%{} = map) do
    Map.new(map, fn {key, value} ->
      cond do
        large_key?(key) ->
          {key, "[OMITTED]"}

        sensitive_key?(key) ->
          {key, "[REDACTED]"}

        true ->
          {key, payload(value)}
      end
    end)
  end

  def payload(values) when is_list(values), do: Enum.map(values, &payload/1)
  def payload(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&payload/1) |> List.to_tuple()
  def payload(value) when is_binary(value), do: text(value)
  def payload(value) when is_pid(value), do: inspect(value)
  def payload(value) when is_function(value), do: inspect(value)
  def payload(value), do: value

  @doc false
  @spec text(String.t()) :: String.t()
  def text(value) when is_binary(value) do
    value
    |> then(&Regex.replace(@key_assignment_pattern, &1, fn _full, key, _value -> "#{key}=[REDACTED]" end))
    |> then(&Regex.replace(@token_pattern, &1, "[REDACTED]"))
  end

  @doc false
  @spec preview(term(), pos_integer()) :: String.t()
  def preview(value, bytes \\ @default_preview_bytes)

  def preview(value, bytes) when is_binary(value) and is_integer(bytes) and bytes > 0 do
    value
    |> text()
    |> String.slice(0, bytes)
  end

  def preview(value, bytes) when is_integer(bytes) and bytes > 0 do
    value
    |> payload()
    |> inspect(limit: 20, printable_limit: bytes)
    |> String.slice(0, bytes)
  end

  @doc false
  @spec sensitive_key?(term()) :: boolean()
  def sensitive_key?(key) when is_atom(key), do: key |> Atom.to_string() |> sensitive_key?()

  def sensitive_key?(key) when is_binary(key) do
    key = String.downcase(key)

    MapSet.member?(@sensitive_exact, key) or
      Enum.any?(@sensitive_contains, &String.contains?(key, &1)) or
      Enum.any?(@sensitive_suffixes, &String.ends_with?(key, &1))
  end

  def sensitive_key?(_key), do: false

  defp large_key?(key) when is_atom(key), do: key |> Atom.to_string() |> large_key?()
  defp large_key?(key) when is_binary(key), do: MapSet.member?(@large_keys, key)
  defp large_key?(_key), do: false
end
