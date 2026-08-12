defmodule Jidoka.Extension.ProcessTransport do
  @moduledoc "Injected transport boundary for a constrained process extension."

  @callback open(descriptor :: map(), opts :: keyword()) ::
              {:ok, handle :: term(), enforcement_evidence :: map()} | {:error, term()}
  @callback exchange(handle :: term(), frame :: binary(), timeout_ms :: pos_integer()) ::
              {:ok, response_line :: binary(), handle :: term()} | {:error, term()}
  @callback notify(handle :: term(), frame :: binary()) :: {:ok, handle :: term()} | {:error, term()}
  @callback cancel(handle :: term(), request_id :: String.t()) :: :ok | {:error, term()}
  @callback close(handle :: term(), opts :: keyword()) :: :ok | {:ok, term()} | {:error, term()}
  @callback diagnostics(handle :: term()) :: map()

  @optional_callbacks diagnostics: 1
end
