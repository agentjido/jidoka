Application.put_env(
  :jidoka,
  :snapshot_signing_secret,
  "example snapshot signing secret must be at least thirty-two bytes"
)

Application.put_env(:tzdata, :autoupdate, :disabled)

if not is_nil(System.get_env("JIDOKA_PROOF_RESULT_PATH")) and
     not Code.ensure_loaded?(JidokaExamples.ExUnitFormatter) do
  Code.require_file("ex_unit_formatter.ex", __DIR__)
end

ExUnit.start(exclude: [:live, :parity])
