defmodule Enclave do
  @moduledoc """
  Provides process-ancestry-based sandboxing for `Phoenix.PubSub`.

  `Enclave` allows concurrent (async) tests to share a single `Phoenix.PubSub`
  instance without leaking broadcasts between test processes. Each test process
  registers itself as an *owner* via `start_owner/0`. Processes spawned from, or
  explicitly allowed by, an owner belong to that owner's *enclave*. A broadcast
  is delivered only to subscribers whose enclave matches the publisher's.

  ## Usage

      # In test setup:
      :ok = Enclave.start_owner()

      # In the application's PubSub wrapper (test env only), pass Enclave.Dispatcher:
      Phoenix.PubSub.broadcast(MyApp.PubSub, topic, msg, Enclave.Dispatcher)

  See `Enclave.Dispatcher` for integration details.
  """

  alias Enclave.Owners

  @type owner_result :: {:ok, pid} | :no_owner

  @doc """
  Registers the calling process as an enclave owner.

  Returns `:ok` if registration succeeds, or `{:error, :already_registered}`
  if the process is already registered.
  """
  @spec start_owner() :: :ok | {:error, :already_registered}
  def start_owner, do: Owners.register_owner(self())

  @doc """
  Unregisters the calling process as an enclave owner.

  Removes all allowances associated with this process.
  """
  @spec stop_owner() :: :ok
  def stop_owner, do: Owners.unregister_owner(self())

  @doc """
  Associates `allowed` with `owner`'s enclave.

  The `owner` must already be a registered owner. Returns `:ok` on success,
  or `{:error, :not_an_owner}` if `owner` is not registered.
  """
  @spec allow(pid, pid) :: :ok | {:error, :not_an_owner}
  def allow(owner, allowed) when is_pid(owner) and is_pid(allowed) do
    Owners.allow(owner, allowed)
  end

  @doc """
  Resolves a pid to its enclave owner.

  Checks the following sources in order:

    1. Direct registration via `start_owner/0` or `allow/2`.
    2. The `$callers` chain in the process dictionary.
    3. The `$ancestors` chain in the process dictionary.

  Returns `{:ok, owner_pid}` if an owner is found, or `:no_owner` otherwise.

  ## Examples

  A process created with `spawn/1` has no OTP ancestry and no registration:

      iex> pid = spawn(fn -> Process.sleep(:infinity) end)
      iex> Enclave.owner(pid)
      :no_owner
  """
  @spec owner(pid) :: owner_result
  def owner(pid) when is_pid(pid) do
    case Owners.lookup(pid) do
      {:ok, owner} -> {:ok, owner}
      :error -> walk_ancestry(pid)
    end
  end

  @doc """
  Determines whether a message from `from_pid` should be delivered to `to_pid`.

  Returns `true` if both pids resolve to the same owner, including both
  resolving to `:no_owner`. Returns `false` otherwise. This means:

    * Same-enclave deliveries are permitted.
    * Unowned-to-unowned deliveries are permitted (the production path).
    * Cross-enclave deliveries are filtered.
    * Owned-to-unowned and unowned-to-owned deliveries are filtered.

  ## Examples

  Two unowned processes are deliverable to each other:

      iex> a = spawn(fn -> Process.sleep(:infinity) end)
      iex> b = spawn(fn -> Process.sleep(:infinity) end)
      iex> Enclave.deliverable?(a, b)
      true
  """
  @spec deliverable?(pid, pid) :: boolean
  def deliverable?(from_pid, to_pid) when is_pid(from_pid) and is_pid(to_pid) do
    owner(from_pid) == owner(to_pid)
  end

  ## Internal

  defp walk_ancestry(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        callers = Keyword.get(dict, :"$callers", [])
        ancestors = Keyword.get(dict, :"$ancestors", [])
        find_owner_in(callers ++ ancestors)

      _ ->
        :no_owner
    end
  end

  defp find_owner_in([]), do: :no_owner

  defp find_owner_in([pid | rest]) when is_pid(pid) do
    case Owners.lookup(pid) do
      {:ok, owner} -> {:ok, owner}
      :error -> find_owner_in(rest)
    end
  end

  defp find_owner_in([_ | rest]), do: find_owner_in(rest)
end
