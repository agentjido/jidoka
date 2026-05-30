defmodule Jidoka.Memory do
  @moduledoc """
  Data contracts and runtime helpers for visible agent memory.
  """

  @type entry :: Jidoka.Memory.Entry.t()
  @type recall_request :: Jidoka.Memory.RecallRequest.t()
  @type recall_result :: Jidoka.Memory.RecallResult.t()
  @type write_request :: Jidoka.Memory.WriteRequest.t()
  @type write_result :: Jidoka.Memory.WriteResult.t()
  @type compaction :: Jidoka.Memory.Compaction.t()
end
