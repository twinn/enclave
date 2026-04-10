# Enclave

[![CI](https://github.com/twinn/enclave/actions/workflows/ci.yml/badge.svg)](https://github.com/twinn/enclave/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/enclave.svg)](https://hex.pm/packages/enclave)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/enclave)

Process-ancestry-based sandboxing for `Phoenix.PubSub`.

Enclave allows concurrent (async) tests to share a single `Phoenix.PubSub`
instance without leaking broadcasts between test processes. It extends the
Ecto SQL sandbox ownership model -- walking `$callers` and `$ancestors` to
find the owning test process -- to PubSub delivery. A broadcast is delivered
only to subscribers whose enclave matches the publisher's.

## Motivation

When testing a LiveView (or any process subscribing to `Phoenix.PubSub`) with
`async: true`:

1. Test A mounts a LiveView that subscribes to `"user:#{id}"`.
2. Test B, running concurrently, updates a user and broadcasts.
3. Test A's LiveView receives Test B's message, producing a flaky test or
   a test that exits while downstream database work is still in flight.

The Ecto SQL sandbox solves the database half of this problem by scoping
connections to an owning test process. Enclave applies the same approach to
PubSub delivery.

## Installation

Add `:enclave` to the list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:enclave, "~> 0.1.0", only: :test}
  ]
end
```

## Usage

### 1. Wrap the PubSub module

Most Phoenix applications start `Phoenix.PubSub` directly in their
supervision tree:

```elixir
# Before
children = [
  # ...
  {Phoenix.PubSub, name: MyApp.PubSub}
]
```

Replace it with a wrapper module that injects `Enclave.Dispatcher` in the
test environment:

```elixir
# lib/my_app/pub_sub.ex
defmodule MyApp.PubSub do
  @dispatcher (if Mix.env() == :test, do: Enclave.Dispatcher, else: Phoenix.PubSub)

  def child_spec(opts),
    do: Phoenix.PubSub.child_spec(Keyword.put(opts, :name, __MODULE__))

  def subscribe(topic), do: Phoenix.PubSub.subscribe(__MODULE__, topic)
  def unsubscribe(topic), do: Phoenix.PubSub.unsubscribe(__MODULE__, topic)

  def broadcast(topic, msg),
    do: Phoenix.PubSub.broadcast(__MODULE__, topic, msg, @dispatcher)

  def broadcast_from(from, topic, msg),
    do: Phoenix.PubSub.broadcast_from(__MODULE__, from, topic, msg, @dispatcher)

  def local_broadcast(topic, msg),
    do: Phoenix.PubSub.local_broadcast(__MODULE__, topic, msg, @dispatcher)
end
```

Then update the application supervision tree and endpoint configuration:

```elixir
# lib/my_app/application.ex
children = [
  # ...
  MyApp.PubSub
]

# config/config.exs
config :my_app, MyAppWeb.Endpoint,
  pubsub_server: MyApp.PubSub
```

In production, `@dispatcher` is `Phoenix.PubSub` (the default), so the
wrapper compiles to a plain pass-through with no runtime overhead.

### 2. Register the test process as an enclave owner

```elixir
defmodule MyAppWeb.UserLiveTest do
  use MyAppWeb.ConnCase, async: true

  setup do
    :ok = Enclave.start_owner()
    :ok
  end

  test "shows updates for the current user", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/1")
    MyApp.PubSub.broadcast("user:1", {:updated, %{name: "new"}})
    assert render(view) =~ "new"
  end
end
```

A concurrently running test broadcasting to `"user:1"` from its own enclave
will not be delivered to this test's LiveView.

### 3. (Optional) Allow background processes

If a test delegates work to a process that was not spawned from the test
process (for example, a globally registered GenServer), explicitly allow it:

```elixir
:ok = Enclave.start_owner()
:ok = Enclave.allow(self(), Process.whereis(MyApp.Worker))
```

## Ownership resolution

Given any pid, Enclave resolves its owner by checking in order:

1. **Direct registration** -- the pid called `start_owner/0`, or was named in
   an `allow/2` call.
2. **`$callers`** -- the process dictionary key that `Task`, `GenServer`,
   and Phoenix propagate to track caller chains.
3. **`$ancestors`** -- the OTP-managed chain set by `:proc_lib` spawning.

If no match is found, the pid resolves to `:no_owner`. Two pids are
deliverable to each other if they resolve to the same owner, including both
resolving to `:no_owner`. This property is what makes the wrapper a no-op in
production.

## Limitations

- **Phoenix internals bypass the filter.** LiveView channel push fan-out,
  `Endpoint.broadcast/3`, and other framework-level broadcasts call
  `Phoenix.PubSub.broadcast/4` with their own dispatcher. Only broadcasts
  routed through `Enclave.Dispatcher` (via the application wrapper) are
  filtered. For most test suites this covers the broadcast path that
  causes flaky tests.
- **Single-node only.** Cross-node broadcasts delegate to the configured
  PubSub adapter, which is outside of Enclave's scope.
- **Requires a wrapper module.** `Phoenix.PubSub` does not support a
  configurable default dispatcher, so there is no way to enable filtering
  without routing broadcasts through a module the application controls.

## License

MIT -- see [LICENSE](LICENSE).
