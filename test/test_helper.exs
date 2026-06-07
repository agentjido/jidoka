Application.put_env(
  :jidoka,
  :snapshot_signing_secret,
  "test snapshot signing secret must be at least thirty-two bytes"
)

ExUnit.start(exclude: [:live])
