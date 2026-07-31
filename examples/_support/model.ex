defmodule JidokaExamples.Capabilities do
  @moduledoc false

  @definitions %{
    human_review: "Creates and resolves a pending human review.",
    operation_control: "Applies a control before an operation executes.",
    snapshot_resume: "Resumes a hibernated snapshot after a review decision.",
    tool_calling: "Accepts and dispatches a model tool request.",
    tool_observation: "Returns an operation result to the next model input."
  }

  @components %{
    action: "A Jidoka action used by the scenario.",
    agent: "A Jidoka agent used by the scenario."
  }

  @spec definitions() :: %{atom() => String.t()}
  def definitions, do: @definitions

  @spec components() :: %{atom() => String.t()}
  def components, do: @components

  @spec names() :: [atom()]
  def names, do: @definitions |> Map.keys() |> Enum.sort()

  @spec component_names() :: [atom()]
  def component_names, do: @components |> Map.keys() |> Enum.sort()

  @spec known?(term()) :: boolean()
  def known?(name), do: Map.has_key?(@definitions, name)

  @spec known_use?(term()) :: boolean()
  def known_use?(name), do: known?(name) or Map.has_key?(@components, name)
end

defmodule JidokaExamples.ScenarioCase do
  @moduledoc false

  @enforce_keys [:id, :proves, :uses]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: atom(),
          proves: [atom()],
          uses: [atom()]
        }
end

defmodule JidokaExamples.Scenario do
  @moduledoc false

  @enforce_keys [:cases, :execution, :id, :intent, :title]
  defstruct @enforce_keys

  @type execution_mode :: :deterministic | :external

  @type t :: %__MODULE__{
          cases: [JidokaExamples.ScenarioCase.t()],
          execution: execution_mode(),
          id: atom(),
          intent: String.t(),
          title: String.t()
        }
end

defmodule JidokaExamples.ShowcaseSurface do
  @moduledoc false

  @enforce_keys [:live_view, :route, :sources, :tests, :view]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          live_view: module(),
          route: String.t(),
          sources: [String.t()],
          tests: [String.t()],
          view: module()
        }
end

defmodule JidokaExamples.Manifest do
  @moduledoc false

  @enforce_keys [
    :agent,
    :dir,
    :lib_dir,
    :livebook,
    :manifest,
    :module,
    :name,
    :readme,
    :root,
    :scenarios,
    :showcase,
    :summary,
    :support_dir,
    :test_files,
    :title,
    :version
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          agent: module(),
          dir: String.t(),
          lib_dir: String.t(),
          livebook: String.t(),
          manifest: String.t(),
          module: module(),
          name: atom(),
          readme: String.t(),
          root: String.t(),
          scenarios: [JidokaExamples.Scenario.t()],
          showcase: JidokaExamples.ShowcaseSurface.t() | nil,
          summary: String.t(),
          support_dir: String.t(),
          test_files: [String.t()],
          title: String.t(),
          version: pos_integer()
        }
end

defmodule JidokaExamples.ExUnitResult do
  @moduledoc false

  @enforce_keys [:case_id, :duration_ms, :example, :failure, :scenario, :status, :test]
  defstruct @enforce_keys

  @type status :: :passed | :failed | :skipped | :excluded | :timed_out

  @type t :: %__MODULE__{
          case_id: atom(),
          duration_ms: non_neg_integer(),
          example: atom(),
          failure: String.t() | nil,
          scenario: atom(),
          status: status(),
          test: %{file: String.t(), line: non_neg_integer(), name: String.t()}
        }
end

defmodule JidokaExamples.CaseResult do
  @moduledoc false

  @enforce_keys [
    :agent,
    :case_id,
    :duration_ms,
    :example,
    :execution,
    :failure,
    :proves,
    :scenario,
    :status,
    :test,
    :uses
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          agent: module(),
          case_id: atom(),
          duration_ms: non_neg_integer(),
          example: atom(),
          execution: JidokaExamples.Scenario.execution_mode(),
          failure: String.t() | nil,
          proves: [atom()],
          scenario: atom(),
          status: JidokaExamples.ExUnitResult.status(),
          test: %{file: String.t(), line: non_neg_integer(), name: String.t()},
          uses: [atom()]
        }
end

defmodule JidokaExamples.GateResult do
  @moduledoc false

  @enforce_keys [:duration_ms, :id, :scope, :status, :subject]
  defstruct [:command, :message, :output | @enforce_keys]

  @type status :: :ok | :error | :skipped
  @type scope :: :catalog | :documentation | :guide | :infrastructure | :scenario | :showcase

  @type t :: %__MODULE__{
          command: [String.t()] | nil,
          duration_ms: non_neg_integer(),
          id: atom(),
          message: String.t() | nil,
          output: String.t() | nil,
          scope: scope(),
          status: status(),
          subject: atom() | String.t()
        }
end

defmodule JidokaExamples.ProofReport do
  @moduledoc false

  @enforce_keys [:cases, :coverage, :gates, :schema_version, :selection, :status]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          cases: [JidokaExamples.CaseResult.t()],
          coverage: map(),
          gates: [JidokaExamples.GateResult.t()],
          schema_version: pos_integer(),
          selection: map(),
          status: :ok | :error
        }
end
