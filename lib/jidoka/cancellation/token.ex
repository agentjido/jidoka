defmodule Jidoka.Cancellation.Token do
  @moduledoc false

  @enforce_keys [:ref, :owner]
  defstruct [:ref, :owner]

  @opaque t :: %__MODULE__{ref: reference(), owner: pid()}

  @spec new() :: t()
  def new do
    %__MODULE__{ref: :atomics.new(1, signed: false), owner: self()}
  end

  @spec request(t()) :: :ok
  def request(%__MODULE__{ref: ref}) do
    :ok = :atomics.put(ref, 1, 1)
  end

  @spec requested?(t()) :: boolean()
  def requested?(%__MODULE__{ref: ref}), do: :atomics.get(ref, 1) == 1

  @spec register(t(), pid()) :: :ok
  def register(%__MODULE__{owner: owner}, pid \\ self()) when is_pid(pid) do
    send(owner, {:jidoka_cancellation_member, pid})
    :ok
  end
end
