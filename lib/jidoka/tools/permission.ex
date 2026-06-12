defmodule Jidoka.Tools.Permission do
  @moduledoc false

  @type mode :: :read_only | :workspace_write | :danger_full_access | :prompt | :allow
  @type requirement :: :read | :write | :danger

  @modes [:read_only, :workspace_write, :danger_full_access, :prompt, :allow]
  @requirements [:read, :write, :danger]

  @spec modes() :: [mode()]
  def modes, do: @modes

  @spec requirements() :: [requirement()]
  def requirements, do: @requirements

  @spec normalize_mode(term()) :: mode()
  def normalize_mode(:read_only), do: :read_only
  def normalize_mode(:workspace_write), do: :workspace_write
  def normalize_mode(:danger_full_access), do: :danger_full_access
  def normalize_mode(:prompt), do: :prompt
  def normalize_mode(:allow), do: :allow
  def normalize_mode("read_only"), do: :read_only
  def normalize_mode("read-only"), do: :read_only
  def normalize_mode("workspace_write"), do: :workspace_write
  def normalize_mode("workspace-write"), do: :workspace_write
  def normalize_mode("danger_full_access"), do: :danger_full_access
  def normalize_mode("danger-full-access"), do: :danger_full_access
  def normalize_mode("prompt"), do: :prompt
  def normalize_mode("allow"), do: :allow
  def normalize_mode(_), do: :read_only

  @spec normalize_requirement(term()) :: requirement()
  def normalize_requirement(:read), do: :read
  def normalize_requirement(:write), do: :write
  def normalize_requirement(:danger), do: :danger
  def normalize_requirement("read"), do: :read
  def normalize_requirement("write"), do: :write
  def normalize_requirement("danger"), do: :danger
  def normalize_requirement(_), do: :danger

  @spec allowed?(term(), term()) :: boolean()
  def allowed?(mode, requirement) do
    mode = normalize_mode(mode)
    requirement = normalize_requirement(requirement)

    mode_rank(mode) >= requirement_rank(requirement)
  end

  @spec check(term(), term()) :: :ok | {:error, map()}
  def check(mode, requirement) do
    mode = normalize_mode(mode)
    requirement = normalize_requirement(requirement)

    if allowed?(mode, requirement) do
      :ok
    else
      {:error,
       %{
         type: :permission_denied,
         permission_mode: mode,
         required_permission: requirement
       }}
    end
  end

  defp mode_rank(:read_only), do: 0
  defp mode_rank(:prompt), do: 0
  defp mode_rank(:workspace_write), do: 1
  defp mode_rank(:danger_full_access), do: 2
  defp mode_rank(:allow), do: 3

  defp requirement_rank(:read), do: 0
  defp requirement_rank(:write), do: 1
  defp requirement_rank(:danger), do: 2
end
