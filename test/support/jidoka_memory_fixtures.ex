defmodule JidokaTest.MemoryAgent do
  use Jidoka.Agent

  agent :memory_agent do
    model :fast
    instructions "You have conversation memory."
  end

  def memory_config do
    %{
      mode: :conversation,
      namespace: {:context, :session},
      capture: :conversation,
      retrieve: %{limit: 4},
      inject: :instructions
    }
  end
end

defmodule JidokaTest.ContextMemoryAgent do
  use Jidoka.Agent

  agent :context_memory_agent do
    model :fast
    instructions "You have context memory."
  end

  def memory_config do
    %{
      mode: :conversation,
      namespace: {:context, :session},
      capture: :conversation,
      retrieve: %{limit: 4},
      inject: :context
    }
  end
end

defmodule JidokaTest.SharedMemoryAgent do
  use Jidoka.Agent

  agent :shared_memory_agent do
    model :fast
    instructions "You have shared memory."
  end

  def memory_config do
    %{
      mode: :conversation,
      namespace: {:shared, "shared-demo"},
      capture: :conversation,
      retrieve: %{limit: 4},
      inject: :context
    }
  end
end

defmodule JidokaTest.NoCaptureMemoryAgent do
  use Jidoka.Agent

  agent :no_capture_memory_agent do
    model :fast
    instructions "You have retrieval only memory."
  end

  def memory_config do
    %{
      mode: :conversation,
      namespace: {:context, :session},
      capture: :off,
      retrieve: %{limit: 4},
      inject: :context
    }
  end
end
