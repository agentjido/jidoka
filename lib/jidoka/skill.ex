defmodule Jidoka.Skill do
  @moduledoc """
  Public helpers for Jido AI skills used by the Jidoka DSL.

  The public API stays stable here. A private adapter owns the Jido-specific
  implementation.
  """

  alias Jidoka.Adapter.Jido.Skill, as: JidoSkill

  @type ref :: module() | String.t()

  @doc "Validates a skill reference from the DSL or imported agent spec."
  defdelegate validate_ref(ref), to: JidoSkill

  @doc "Validates a skill load path before it is expanded."
  defdelegate validate_load_path(path), to: JidoSkill

  @doc "Resolves skill references into one stable ordered snapshot."
  defdelegate resolve(refs, opts \\ []), to: JidoSkill

  @doc "Returns action modules contributed by skill references."
  defdelegate action_modules(refs, opts \\ []), to: JidoSkill

  @doc "Renders prompt text contributed by skill references."
  defdelegate prompt(refs, opts \\ []), to: JidoSkill

  @doc "Returns serializable metadata for resolved skill references."
  defdelegate metadata(refs, opts \\ []), to: JidoSkill

  @doc "Expands skill load paths relative to a base directory."
  defdelegate normalize_load_paths(paths, base_dir), to: JidoSkill
end
