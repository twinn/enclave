{:ok, _} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: Enclave.TestPubSub}],
    strategy: :one_for_one
  )

ExUnit.start()
