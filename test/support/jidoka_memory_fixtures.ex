defmodule JidokaTest.MemoryAgent do
  use Jidoka.Agent

  agent :memory_agent do
    model :fast
    instructions "You have conversation memory."
  end

  lifecycle do
    memory do
      mode :conversation
      namespace {:context, :session}
      capture :conversation
      retrieve limit: 4
      inject :instructions
    end
  end
end

defmodule JidokaTest.ContextMemoryAgent do
  use Jidoka.Agent

  agent :context_memory_agent do
    model :fast
    instructions "You have context memory."
  end

  lifecycle do
    memory do
      mode :conversation
      namespace {:context, :session}
      capture :conversation
      retrieve limit: 4
      inject :context
    end
  end
end

defmodule JidokaTest.SharedMemoryAgent do
  use Jidoka.Agent

  agent :shared_memory_agent do
    model :fast
    instructions "You have shared memory."
  end

  lifecycle do
    memory do
      mode :conversation
      namespace :shared
      shared_namespace "shared-demo"
      capture :conversation
      retrieve limit: 4
      inject :context
    end
  end
end

defmodule JidokaTest.NoCaptureMemoryAgent do
  use Jidoka.Agent

  agent :no_capture_memory_agent do
    model :fast
    instructions "You have retrieval only memory."
  end

  lifecycle do
    memory do
      mode :conversation
      namespace {:context, :session}
      capture :off
      retrieve limit: 4
      inject :context
    end
  end
end
