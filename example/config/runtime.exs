import Config

example_root = Path.expand("..", __DIR__)
package_root = Path.expand("..", example_root)

env_files = [
  Path.join(package_root, ".env"),
  Path.join(example_root, ".env")
]

dotenv_files = Enum.filter(env_files, &File.exists?/1)
env = Dotenvy.source!([System.get_env() | dotenv_files] ++ [System.get_env()])

api_key_env =
  env
  |> Enum.filter(fn {key, value} ->
    String.ends_with?(key, "_API_KEY") and is_binary(value) and String.trim(value) != ""
  end)
  |> Map.new()

browser_env =
  env
  |> Map.take(["JIDO_BROWSER_AGENT_BROWSER_BINARY_PATH"])
  |> Map.reject(fn {_key, value} -> not is_binary(value) or String.trim(value) == "" end)

System.put_env(Map.merge(api_key_env, browser_env))

config :jido_browser,
  brave_api_key: env["BRAVE_SEARCH_API_KEY"]

agent_browser_path =
  env["JIDO_BROWSER_AGENT_BROWSER_BINARY_PATH"] ||
    if Code.ensure_loaded?(Jido.Browser.Installer) do
      Jido.Browser.Installer.bin_path(:agent_browser)
    end

if is_binary(agent_browser_path) and File.exists?(agent_browser_path) do
  config :jido_browser, :agent_browser, binary_path: agent_browser_path
end

present? = fn value -> is_binary(value) and String.trim(value) != "" end
default_model = Jidoka.Config.model_ref(Jidoka.Config.default_model())

config :jidoka_example,
  default_model: default_model,
  live_llm_ready?: present?.(env["OPENAI_API_KEY"]) or present?.(env["ANTHROPIC_API_KEY"]),
  live_research_ready?:
    (present?.(env["OPENAI_API_KEY"]) or present?.(env["ANTHROPIC_API_KEY"])) and
      present?.(env["BRAVE_SEARCH_API_KEY"])
