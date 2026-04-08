defmodule Enclave do
  @moduledoc """
  Process-ancestry-based sandboxing for Phoenix.PubSub (and any pid-keyed
  fan-out mechanism).

  Enclave lets async tests share a single Phoenix.PubSub instance without
  leaking broadcasts between tests. Each test process registers itself as an
  *owner*; processes spawned from (or explicitly allowed by) an owner are
  members of that owner's *enclave*. A broadcast is only delivered to
  subscribers whose enclave matches the publisher's.

  ## Basic usage

      # In test setup:
      :ok = Enclave.start_owner()

      # In your app's PubSub wrapper (test env only), pass Enclave.Dispatcher:
      Phoenix.PubSub.broadcast(MyApp.PubSub.Instance, topic, msg, Enclave.Dispatcher)

  See `Enclave.Dispatcher` for integration details.
  """

  alias Enclave.Owners

  @type owner_result :: {:ok, pid} | :no_owner

  @doc """
  Register `self()` as an enclave owner.
  """
  @spec start_owner() :: :ok | {:error, :already_registered}
  def start_owner, do: Owners.register_owner(self())

  @doc """
  Unregister `self()` as an enclave owner. Removes all allowances pointing to
  this process.
  """
  @spec stop_owner() :: :ok
  def stop_owner, do: Owners.unregister_owner(self())

  @doc """
  Explicitly associate `allowed` with `owner`'s enclave. `owner` must already
  be a registered owner.
  """
  @spec allow(pid, pid) :: :ok | {:error, :not_an_owner}
  def allow(owner, allowed) when is_pid(owner) and is_pid(allowed) do
    Owners.allow(owner, allowed)
  end

  @doc """
  Resolve a pid to its enclave owner.

  Resolution order:

    1. Direct registration (explicit `start_owner`/`allow`).
    2. `$callers` chain from the process dictionary.
    3. `$ancestors` chain from the process dictionary.

  Returns `{:ok, owner_pid}` or `:no_owner`.

  ## Examples

  A bare `spawn/1` process has no OTP ancestry and no registration, so it
  is always `:no_owner`:

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
  Should a message from `from_pid` be delivered to `to_pid`?

  The rule is simple: both pids must resolve to the same owner, OR both must
  resolve to `:no_owner`. Everything else is dropped. This means:

    * same-test deliveries pass
    * pure-production (unowned) deliveries pass
    * cross-test deliveries are dropped
    * test → production and production → test are dropped

  ## Examples

  Two processes with no enclave resolve to `:no_owner`, so they are
  deliverable (this is what makes the wrapper a no-op in production):

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
