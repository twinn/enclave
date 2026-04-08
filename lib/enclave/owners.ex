defmodule Enclave.Owners do
  @moduledoc false
  # ETS-backed registry mapping `allowed_pid → owner_pid`.
  #
  # An "owner" is a process that has called `Enclave.start_owner/0`. Every owner
  # has a self-entry (`{owner, owner}`). Additional entries are added via
  # `Enclave.allow/2` for processes that should inherit the owner's enclave
  # (e.g. long-lived workers that didn't descend from the test process).
  #
  # The GenServer monitors every tracked pid. When an owner dies, every entry
  # pointing to it (including its own self-entry) is removed. When an allowed
  # pid dies, only its own row is removed.

  use GenServer

  @table __MODULE__

  ## Public API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc "Register `pid` as an owner. Idempotent failure: returns `{:error, :already_registered}`."
  def register_owner(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:register_owner, pid})
  end

  @doc "Unregister `pid` as an owner and remove all entries pointing to it."
  def unregister_owner(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:unregister_owner, pid})
  end

  @doc """
  Explicitly associate `allowed` with `owner`. `owner` must already be registered.
  """
  def allow(owner, allowed) when is_pid(owner) and is_pid(allowed) do
    GenServer.call(__MODULE__, {:allow, owner, allowed})
  end

  @doc """
  Direct ETS lookup — no ancestry walking. Returns `{:ok, owner_pid}` or `:error`.
  """
  def lookup(pid) when is_pid(pid) do
    case :ets.lookup(@table, pid) do
      [{^pid, owner}] -> {:ok, owner}
      [] -> :error
    end
  end

  ## GenServer callbacks

  @impl true
  def init(_) do
    @table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    # state.monitors: %{monitor_ref => pid}
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:register_owner, pid}, _from, state) do
    case :ets.lookup(@table, pid) do
      [{^pid, ^pid}] ->
        {:reply, {:error, :already_registered}, state}

      _ ->
        true = :ets.insert(@table, {pid, pid})
        ref = Process.monitor(pid)
        {:reply, :ok, put_monitor(state, ref, pid)}
    end
  end

  def handle_call({:unregister_owner, pid}, _from, state) do
    state = remove_owner(pid, state)
    {:reply, :ok, state}
  end

  def handle_call({:allow, owner, allowed}, _from, state) do
    case :ets.lookup(@table, owner) do
      [{^owner, ^owner}] ->
        true = :ets.insert(@table, {allowed, owner})

        state =
          if allowed == owner do
            state
          else
            ref = Process.monitor(allowed)
            put_monitor(state, ref, allowed)
          end

        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_an_owner}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {^pid, monitors} ->
        # Was `pid` an owner? If so, wipe everything pointing to it.
        # Either way, remove its own row (if any).
        case :ets.lookup(@table, pid) do
          [{^pid, ^pid}] ->
            :ets.match_delete(@table, {:_, pid})

          _ ->
            :ets.delete(@table, pid)
        end

        {:noreply, %{state | monitors: monitors}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Helpers

  defp put_monitor(state, ref, pid) do
    %{state | monitors: Map.put(state.monitors, ref, pid)}
  end

  defp remove_owner(pid, state) do
    case :ets.lookup(@table, pid) do
      [{^pid, ^pid}] ->
        # Find all entries owned by `pid` and demonitor/remove them.
        owned = :ets.match_object(@table, {:_, pid})
        :ets.match_delete(@table, {:_, pid})

        owned_pids = Enum.map(owned, fn {p, _} -> p end)

        {removed, kept} =
          Enum.split_with(state.monitors, fn {_ref, monitored} ->
            monitored in owned_pids
          end)

        Enum.each(removed, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)
        %{state | monitors: Map.new(kept)}

      _ ->
        state
    end
  end
end
