defmodule JidokaExample.Env do
  @moduledoc false

  @example_root Path.expand("../..", __DIR__)
  @package_root Path.expand("..", @example_root)

  @env_files [
    Path.join(@package_root, ".env"),
    Path.join(@example_root, ".env")
  ]

  def load! do
    env =
      [System.get_env()]
      |> Kernel.++(Enum.filter(@env_files, &File.exists?/1))
      |> Kernel.++([System.get_env()])
      |> Dotenvy.source!()

    System.put_env(env)
    Application.put_env(:req_llm, :load_dotenv, false)
    put_req_llm_env(:openai_api_key, env["OPENAI_API_KEY"])
    put_req_llm_env(:anthropic_api_key, env["ANTHROPIC_API_KEY"])

    env
  end

  def live_ready?(env \\ System.get_env()) do
    present?(env["OPENAI_API_KEY"]) or present?(env["ANTHROPIC_API_KEY"])
  end

  def model(env \\ System.get_env()) do
    first_present([
      env["JIDOKA_EXAMPLE_MODEL"],
      env["JIDOKA_DEFAULT_MODEL"],
      env["JIDOKA_LIVE_MODEL"],
      "openai:gpt-4o-mini"
    ])
  end

  def env_files, do: @env_files

  defp put_req_llm_env(_key, value) when value in [nil, ""], do: :ok
  defp put_req_llm_env(key, value), do: Application.put_env(:req_llm, key, value)

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
