# Enclave

[![CI](https://github.com/twinn/enclave/actions/workflows/ci.yml/badge.svg)](https://github.com/twinn/enclave/actions/workflows/ci.yml)

Process-ancestry-based sandboxing for `Phoenix.PubSub`.

Enclave lets async tests share a single `Phoenix.PubSub` instance without
leaking broadcasts between tests. It extends the Ecto SQL sandbox's
ownership model — walking `$callers` and `$ancestors` to find the "owning"
test process — to PubSub delivery. A broadcast is only delivered to
subscribers whose enclave matches the publisher's.

## Why

When you test a LiveView (or anything subscribing to `Phoenix.PubSub`) with
`async: true`:

1. Test A mounts a LiveView that subscribes to `"user:#{id}"`.
2. Test B, running concurrently, updates a user and broadcasts.
3. Test A's LiveView receives Test B's message — a flaky test, or worse, a
   test that exits while downstream DB work is still in flight.

The Ecto SQL sandbox solves the *database* half of this by scoping
connections to an owning test process. Enclave does the same thing for
PubSub delivery.

## Installation

```elixir
def deps do
  [
    {:enclave, "~> 0.1.0", only: :test}
  ]
end
```

## Usage

### 1. Wrap your PubSub

Most Phoenix apps start `Phoenix.PubSub` directly in their supervision tree:

```elixir
# Before
children = [
  # ...
  {Phoenix.PubSub, name: MyApp.PubSub}
]
```

Replace it with a thin wrapper module that injects `Enclave.Dispatcher` in
test env only:

```elixir
# lib/my_app/pub_sub.ex
defmodule MyApp.PubSub do
  @name __MODULE__.Instance

  @dispatcher (if Mix.env() == :test, do: Enclave.Dispatcher, else: Phoenix.PubSub)

  def child_spec(opts),
    do: Phoenix.PubSub.child_spec(Keyword.put(opts, :name, @name))

  def name, do: @name

  def subscribe(topic), do: Phoenix.PubSub.subscribe(@name, topic)
  def unsubscribe(topic), do: Phoenix.PubSub.unsubscribe(@name, topic)

  def broadcast(topic, msg),
    do: Phoenix.PubSub.broadcast(@name, topic, msg, @dispatcher)

  def broadcast_from(from, topic, msg),
    do: Phoenix.PubSub.broadcast_from(@name, from, topic, msg, @dispatcher)

  def local_broadcast(topic, msg),
    do: Phoenix.PubSub.local_broadcast(@name, topic, msg, @dispatcher)
end
```

Then in your application and endpoint config:

```elixir
# lib/my_app/application.ex
children = [
  # ...
  MyApp.PubSub
]

# config/config.exs
config :my_app, MyAppWeb.Endpoint,
  pubsub_server: MyApp.PubSub.Instance
```

In production `@dispatcher` is `Phoenix.PubSub` (the default), so the
wrapper compiles away to a plain pass-through — zero runtime overhead.

### 2. Mark your test as an enclave owner

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

That's it. A concurrently running test broadcasting to `"user:1"` in its
own enclave will not be seen by this test's LiveView.

### 3. (Optional) Allow background processes

If your test hands work to a worker that wasn't spawned from the test
process (e.g. a globally-registered GenServer), explicitly allow it:

```elixir
:ok = Enclave.start_owner()
:ok = Enclave.allow(self(), Process.whereis(MyApp.Worker))
```

## How ownership is resolved

Given any pid, Enclave finds its owner by checking in order:

1. **Direct registration** — the pid called `start_owner/0`, or was named in
   an `allow/2` call.
2. **`$callers`** — the process dictionary key that `Task`, `GenServer`,
   and Phoenix propagate to track caller chains.
3. **`$ancestors`** — the OTP-managed chain set by `:proc_lib` spawning.

If nothing matches, the pid is `:no_owner`. Two pids are deliverable if
they resolve to the same owner — *including* both resolving to `:no_owner`,
which is what makes the wrapper a no-op in production.

## Limitations

- **Phoenix internals bypass the filter.** LiveView's channel push
  fan-out, `Endpoint.broadcast/3`, and other framework-level broadcasts
  call `Phoenix.PubSub.broadcast/4` with their own dispatcher. Only
  broadcasts that go through `Enclave.Dispatcher` (i.e. your app's own
  code going through the wrapper) get filtered. For most test suites this
  is exactly the broadcast path that causes flake, but it's worth
  knowing.
- **Single-node only.** Cross-node broadcasts delegate to the configured
  PubSub adapter, which is out of Enclave's reach. Don't use this in
  clustered tests.
- **Requires a wrapper.** `Phoenix.PubSub` doesn't support a configurable
  default dispatcher, so there's no way to enable filtering without
  routing broadcasts through a module you control. An upstream PR
  adding `config :phoenix_pubsub, default_dispatcher:` would let this
  library drop the wrapper entirely.

## License

MIT — see [LICENSE](LICENSE).
