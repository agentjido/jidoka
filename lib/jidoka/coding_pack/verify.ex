defmodule Jidoka.CodingPack.Verify do
  @moduledoc "Trusted named test and lint helpers through a constrained environment."

  alias Jidoka.CodingPack.{Error, Ignore, ShellPort, VerifyPort, Workspace}

  @keys ~w(helper_id target edit_ids checkpoint_ids)

  @doc "Returns the model-visible named verification operation and handler."
  @spec tool(Workspace.t(), VerifyPort.t()) :: %{operation: Jidoka.Agent.Spec.Operation.t(), handler: function()}
  def tool(%Workspace{} = workspace, %VerifyPort{} = port) do
    %{
      operation:
        Jidoka.Agent.Spec.Operation.new!(
          name: "coding.verify",
          description: "Run one trusted named test or lint helper.",
          idempotency: :reconcile,
          metadata: %{
            "kind" => "tool",
            "source" => "coding_pack",
            "parameters_schema" => input_schema(),
            "policy_resource" => %{
              "kind" => "coding_workspace",
              "access" => "verify",
              "argument_fields" => ["helper_id", "target", "edit_ids", "checkpoint_ids"]
            }
          }
        ),
      handler: fn arguments, context ->
        run(workspace, port, arguments, cancellation: Jidoka.Context.get_runtime(context, :cancellation))
      end
    }
  end

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "helper_id" => %{"type" => "string", "minLength" => 1},
        "target" => %{"type" => "string", "minLength" => 1},
        "edit_ids" => %{
          "type" => "array",
          "items" => %{"type" => "string", "minLength" => 1},
          "maxItems" => 50
        },
        "checkpoint_ids" => %{
          "type" => "array",
          "items" => %{"type" => "string", "minLength" => 1},
          "maxItems" => 50
        }
      },
      "required" => ["helper_id"],
      "additionalProperties" => false
    }
  end

  @doc "Runs one trusted helper after target and workspace checks."
  @spec run(Workspace.t(), VerifyPort.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(workspace, port, arguments, opts \\ [])

  def run(%Workspace{} = workspace, %VerifyPort{} = port, arguments, opts)
      when is_map(arguments) and is_list(opts) do
    with true <- Workspace.permits?(workspace, :verify),
         {:ok, input} <- input(arguments),
         {:ok, helper} <- VerifyPort.fetch(port, input.helper_id),
         true <- helper.timeout_ms <= workspace.limits.max_shell_timeout_ms,
         {:ok, target} <- target(workspace, helper, input.target),
         args = substitute(helper.args, target),
         {:ok, shell} <-
           ShellPort.execute(
             port.shell,
             workspace,
             %{
               command: helper.command,
               args: args,
               stdin: "",
               cwd: ".",
               timeout_ms: helper.timeout_ms,
               max_output_bytes: workspace.limits.max_shell_output_bytes,
               network: helper.network
             },
             opts
           ) do
      {:ok, result(shell, helper, target, input)}
    else
      false -> {:error, Error.new(:coding_verify_denied)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def run(%Workspace{}, %VerifyPort{}, _arguments, _opts),
    do: {:error, Error.new(:coding_verify_input_invalid)}

  defp target(_workspace, %{target_required: false, targets: []}, nil), do: {:ok, nil}

  defp target(_workspace, %{target_required: false, targets: []}, _target),
    do: {:error, Error.new(:coding_verify_target_forbidden)}

  defp target(_workspace, %{target_required: true}, nil),
    do: {:error, Error.new(:coding_verify_target_required)}

  defp target(workspace, helper, target) when is_binary(target) do
    with false <- String.starts_with?(target, "-"),
         {:ok, resolved} <- Workspace.resolve(workspace, target),
         {:ok, %{ignored?: false}} <- Ignore.decision(workspace, resolved.relative),
         true <- Enum.any?(helper.target_patterns, &Regex.match?(&1, resolved.relative)) do
      {:ok, resolved.relative}
    else
      true -> {:error, Error.new(:coding_verify_target_unsafe, %{target: target})}
      false -> {:error, Error.new(:coding_verify_target_denied, %{target: target})}
      {:ok, decision} -> {:error, Error.new(:coding_path_ignored, %{target: target, decision: decision})}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp target(_workspace, _helper, _target), do: {:error, Error.new(:coding_verify_target_invalid)}

  defp substitute(args, nil), do: args
  defp substitute(args, target), do: Enum.map(args, &if(&1 == "{target}", do: target, else: &1))

  defp result(shell, helper, target, input) do
    passed = shell["status"] in ["ok", "nonzero"] and shell["exit_status"] in helper.exit_codes

    shell
    |> Map.put("status", verify_status(shell["status"], passed))
    |> Map.put("helper_id", helper.id)
    |> Map.put("description", helper.description)
    |> Map.put("target", target)
    |> Map.put("edit_ids", input.edit_ids)
    |> Map.put("checkpoint_ids", input.checkpoint_ids)
    |> Map.put("passed", passed)
  end

  defp verify_status(_shell_status, true), do: "passed"
  defp verify_status("timeout", false), do: "timeout"
  defp verify_status("cancelled", false), do: "cancelled"
  defp verify_status("blocked", false), do: "blocked"
  defp verify_status(_shell_status, false), do: "failed"

  defp input(arguments) do
    arguments = stringify_keys(arguments)
    unknown = Map.keys(arguments) -- @keys
    helper_id = Map.get(arguments, "helper_id")
    target = Map.get(arguments, "target")
    edit_ids = Map.get(arguments, "edit_ids", [])
    checkpoint_ids = Map.get(arguments, "checkpoint_ids", [])

    if unknown == [] and is_binary(helper_id) and helper_id != "" and optional_string?(target) and
         id_list?(edit_ids) and id_list?(checkpoint_ids),
       do: {:ok, %{helper_id: helper_id, target: target, edit_ids: edit_ids, checkpoint_ids: checkpoint_ids}},
       else: {:error, Error.new(:coding_verify_input_invalid)}
  end

  defp optional_string?(nil), do: true
  defp optional_string?(value), do: is_binary(value) and value != ""

  defp id_list?(values),
    do: is_list(values) and length(values) <= 50 and Enum.all?(values, &(is_binary(&1) and &1 != ""))

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
