defmodule Jidoka.TestAttemptExecutionAdapters.Success do
  @moduledoc "Stub adapter that emits progress and succeeds."

  @behaviour Jidoka.AttemptExecution

  alias Jidoka.AttemptExecution.{AttemptOutput, AttemptSpec, ProgressEvent}

  @impl true
  def execute(%AttemptSpec{} = spec) do
    progress = [
      %ProgressEvent{
        label: :prepare,
        message: "loaded task and workspace",
        metadata: %{
          attempt_id: spec.attempt_id,
          workspace_path: spec.environment_lease.workspace_path
        }
      },
      %ProgressEvent{
        label: :simulate_work,
        message: "worked for no-op adapter",
        metadata: %{adapter: :stub_success}
      }
    ]

    {:ok,
     %AttemptOutput{
       status: :succeeded,
       progress: progress,
       metadata: %{adapter: :stub_success, attempt_number: spec.attempt_number}
     }}
  end
end

defmodule Jidoka.TestAttemptExecutionAdapters.Failure do
  @moduledoc "Stub adapter that reports a hard failure."

  @behaviour Jidoka.AttemptExecution

  alias Jidoka.AttemptExecution.AttemptSpec

  @impl true
  def execute(%AttemptSpec{}) do
    {:error, %{reason: :stubbed_execution_failure}}
  end
end

defmodule Jidoka.TestAttemptExecutionAdapters.PromptSuccess do
  @moduledoc "Stub adapter that simulates a prompt-capable execution path."

  @behaviour Jidoka.AttemptExecution

  alias Jidoka.AttemptExecution
  alias Jidoka.AttemptExecution.{AttemptOutput, AttemptSpec}

  @impl true
  def execute(%AttemptSpec{} = spec) do
    response_text = "stub response for: #{spec.task}"
    prompt_report_path = Path.join(spec.environment_lease.workspace_path, "prompt_report.md")

    :ok =
      AttemptExecution.report_progress(
        spec,
        :runtime_ready,
        "configured fake runtime",
        %{adapter: :stub_prompt}
      )

    :ok =
      AttemptExecution.report_progress(
        spec,
        :prompt_dispatch,
        "submitted prompt to fake agent",
        %{prompt_length: byte_size(spec.task)}
      )

    File.mkdir_p!(spec.environment_lease.workspace_path)

    File.write!(
      prompt_report_path,
      """
      # Prompt

      #{spec.task}

      # Response

      #{response_text}
      """
    )

    :ok =
      AttemptExecution.report_progress(
        spec,
        :prompt_report_written,
        "persisted fake prompt report",
        %{location: prompt_report_path}
      )

    {:ok,
     %AttemptOutput{
       status: :succeeded,
       metadata: %{adapter: :stub_prompt, response_text: response_text},
       artifacts: [
         %{
           id: "artifact-prompt-success-" <> spec.attempt_id,
           type: :prompt_report,
           status: :ready,
           location: prompt_report_path
         }
       ]
     }}
  end
end

defmodule Jidoka.TestAttemptExecutionAdapters.ToolProgress do
  @moduledoc "Stub adapter that executes a Jidoka tool and relies on live tool progress."

  @behaviour Jidoka.AttemptExecution

  alias Jidoka.AttemptExecution.{AttemptOutput, AttemptSpec}

  @impl true
  def execute(%AttemptSpec{} = spec) do
    File.mkdir_p!(spec.environment_lease.workspace_path)
    File.write!(Path.join(spec.environment_lease.workspace_path, "note.txt"), "tool progress\n")

    context = %{
      jidoka_attempt_spec: spec,
      workspace_path: spec.environment_lease.workspace_path,
      permission_mode: :read_only
    }

    case Jidoka.Tools.ReadFile.run(%{path: "note.txt"}, context) do
      {:ok, result} ->
        {:ok,
         %AttemptOutput{
           status: :succeeded,
           metadata: %{adapter: :tool_progress, contents: result.contents}
         }}

      {:error, reason} ->
        {:ok,
         %AttemptOutput{
           status: :terminal_failed,
           metadata: %{adapter: :tool_progress},
           error: reason
         }}
    end
  end
end

defmodule Jidoka.TestAttemptExecutionAdapters.MutationProgress do
  @moduledoc "Stub adapter that executes mutation and check tools for progress coverage."

  @behaviour Jidoka.AttemptExecution

  alias Jidoka.AttemptExecution.{AttemptOutput, AttemptSpec}

  @impl true
  def execute(%AttemptSpec{} = spec) do
    File.mkdir_p!(Path.join(spec.environment_lease.workspace_path, "test"))

    File.write!(
      Path.join(spec.environment_lease.workspace_path, "mix.exs"),
      """
      defmodule ToolProgress.MixProject do
        use Mix.Project

        def project do
          [app: :tool_progress, version: "0.1.0", elixir: "~> 1.19", deps: []]
        end
      end
      """
    )

    File.write!(
      Path.join(spec.environment_lease.workspace_path, "test/test_helper.exs"),
      "ExUnit.start()\n"
    )

    File.write!(
      Path.join(spec.environment_lease.workspace_path, "test/tool_progress_test.exs"),
      """
      defmodule ToolProgressTest do
        use ExUnit.Case

        test "works" do
          assert true
        end
      end
      """
    )

    context = %{
      jidoka_attempt_spec: spec,
      workspace_path: spec.environment_lease.workspace_path,
      permission_mode: :workspace_write
    }

    with {:ok, _write_result} <-
           Jidoka.Tools.WriteFile.run(
             %{path: "lib/generated.txt", contents: "generated\n"},
             context
           ),
         {:ok, _check_result} <-
           Jidoka.Tools.MixCheck.run(%{checks: ["test"], timeout_ms: 120_000}, context) do
      {:ok,
       %AttemptOutput{
         status: :succeeded,
         metadata: %{adapter: :mutation_progress}
       }}
    else
      {:error, reason} ->
        {:ok,
         %AttemptOutput{
           status: :terminal_failed,
           metadata: %{adapter: :mutation_progress},
           error: reason
         }}
    end
  end
end
