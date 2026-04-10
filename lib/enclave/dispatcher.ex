defmodule Enclave.Dispatcher do
  @moduledoc """
  A `Phoenix.PubSub` dispatcher that filters subscribers through
  `Enclave.deliverable?/2` before delivery.

  `Phoenix.PubSub` accepts a dispatcher module as the last argument to
  `broadcast/4`, `broadcast_from/5`, and `local_broadcast/4`. Passing
  `Enclave.Dispatcher` restricts delivery to subscribers that belong to
  the same enclave as the publishing process.

  ## Usage

  A thin wrapper module in the host application conditionally injects
  the dispatcher in test:

      defmodule MyApp.PubSub do
        @dispatcher (if Mix.env() == :test, do: Enclave.Dispatcher, else: Phoenix.PubSub)

        def child_spec(opts),
          do: Phoenix.PubSub.child_spec(Keyword.put(opts, :name, __MODULE__))

        def subscribe(topic), do: Phoenix.PubSub.subscribe(__MODULE__, topic)

        def broadcast(topic, msg),
          do: Phoenix.PubSub.broadcast(__MODULE__, topic, msg, @dispatcher)
      end

  In production, `@dispatcher` is `Phoenix.PubSub` (the default), so the
  wrapper compiles to a plain pass-through with no runtime overhead.
  """

  @doc """
  Dispatches `message` to the given `entries`, filtering by enclave ownership.

  Called by `Phoenix.PubSub` via `Registry.dispatch/3`. Each entry is checked
  with `Enclave.deliverable?/2`; only subscribers in the same enclave as the
  source process receive the message.

  When `from` is `:none`, all enclave-matching subscribers receive the message.
  When `from` is a pid, that pid is additionally excluded from delivery
  (matching the default `Phoenix.PubSub` broadcast-from semantics).
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
