Application.put_env(
  :jidoka,
  :snapshot_signing_secret,
  "test snapshot signing secret must be at least thirty-two bytes"
)

Application.put_env(:tzdata, :autoupdate, :disabled)

ExUnit.start(exclude: [:live])
