defmodule Enclave.Dispatcher do
  @moduledoc """
  A `Phoenix.PubSub` dispatcher that filters subscribers through
  `Enclave.deliverable?/2` before sending.

  Phoenix.PubSub accepts a dispatcher module as the last argument to
  `broadcast/4`, `broadcast_from/5`, `local_broadcast/4`, etc. Passing
  `Enclave.Dispatcher` causes only subscribers in the same enclave as the
  publishing process to receive the message.

  ## Usage

  Typically you wire this in once via a thin wrapper module in your host app:

      defmodule MyApp.PubSub do
        @name __MODULE__.Instance
        @dispatcher (if Mix.env() == :test, do: Enclave.Dispatcher, else: Phoenix.PubSub)

        def child_spec(opts),
          do: Phoenix.PubSub.child_spec(Keyword.put(opts, :name, @name))

        def subscribe(topic), do: Phoenix.PubSub.subscribe(@name, topic)

        def broadcast(topic, msg),
          do: Phoenix.PubSub.broadcast(@name, topic, msg, @dispatcher)
      end

  In production `@dispatcher` is `Phoenix.PubSub` (the default), so this
  indirection compiles away to the same code you would have written by hand.
  """

  @doc """
  Called by `Phoenix.PubSub` via `Registry.dispatch/3`. Filters `entries` by
  `Enclave.deliverable?/2` and sends the message to survivors.

  Matches Phoenix.PubSub's own default dispatch semantics:

    * `from == :none` → deliver to every (allowed) subscriber
    * `from == pid`   → deliver to every (allowed) subscriber except `from`
  """
  @spec dispatch([{pid, term}], pid | :none, term) :: :ok
  def dispatch(entries, :none, message) do
    source = self()

    Enum.each(entries, fn {pid, _value} ->
      if Enclave.deliverable?(source, pid), do: send(pid, message)
    end)

    :ok
  end

  def dispatch(entries, from, message) when is_pid(from) do
    Enum.each(entries, fn {pid, _value} ->
      if pid != from and Enclave.deliverable?(from, pid), do: send(pid, message)
    end)

    :ok
  end
end
