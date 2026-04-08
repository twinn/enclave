defmodule EnclaveTest do
  use ExUnit.Case, async: true

  doctest Enclave

  describe "owner registration" do
    test "a fresh process has no owner" do
      assert Enclave.owner(self()) == :no_owner
    end

    test "start_owner/0 makes self() its own owner" do
      :ok = Enclave.start_owner()
      assert Enclave.owner(self()) == {:ok, self()}
    end

    test "start_owner/0 called twice on same pid returns an error" do
      :ok = Enclave.start_owner()
      assert {:error, :already_registered} = Enclave.start_owner()
    end

    test "stop_owner/0 removes the ownership" do
      :ok = Enclave.start_owner()
      :ok = Enclave.stop_owner()
      assert Enclave.owner(self()) == :no_owner
    end

    test "owner entries are cleaned up when the owner process dies" do
      test_pid = self()

      {:ok, owner_pid} =
        Task.start(fn ->
          :ok = Enclave.start_owner()
          send(test_pid, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered
      assert Enclave.owner(owner_pid) == {:ok, owner_pid}

      ref = Process.monitor(owner_pid)
      send(owner_pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^owner_pid, _}

      # Sync with the Owners GenServer so it processes the DOWN message.
      _ = :sys.get_state(Enclave.Owners)
      assert Enclave.owner(owner_pid) == :no_owner
    end
  end

  describe "allow/2" do
    test "an explicitly allowed pid resolves to the owner" do
      :ok = Enclave.start_owner()
      owner = self()

      {:ok, other} = Agent.start(fn -> :ok end)

      :ok = Enclave.allow(owner, other)
      assert Enclave.owner(other) == {:ok, owner}

      Agent.stop(other)
    end

    test "allow/2 fails if the first argument is not a registered owner" do
      {:ok, a} = Agent.start(fn -> :ok end)
      {:ok, b} = Agent.start(fn -> :ok end)

      assert {:error, :not_an_owner} = Enclave.allow(a, b)

      Agent.stop(a)
      Agent.stop(b)
    end

    test "an allowed pid loses its ownership when the owner dies" do
      test_pid = self()
      {:ok, other} = Agent.start(fn -> :ok end)

      {:ok, owner_pid} =
        Task.start(fn ->
          :ok = Enclave.start_owner()
          :ok = Enclave.allow(self(), other)
          send(test_pid, :ready)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :ready
      assert Enclave.owner(other) == {:ok, owner_pid}

      ref = Process.monitor(owner_pid)
      send(owner_pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^owner_pid, _}

      _ = :sys.get_state(Enclave.Owners)
      assert Enclave.owner(other) == :no_owner

      Agent.stop(other)
    end
  end

  describe "ancestry resolution" do
    test "Tasks spawned from an owner resolve via $callers" do
      :ok = Enclave.start_owner()
      owner = self()

      result = fn -> Enclave.owner(self()) end |> Task.async() |> Task.await()
      assert result == {:ok, owner}
    end

    test "nested Tasks resolve via $callers chain" do
      :ok = Enclave.start_owner()
      owner = self()

      result =
        fn ->
          fn -> Enclave.owner(self()) end |> Task.async() |> Task.await()
        end
        |> Task.async()
        |> Task.await()

      assert result == {:ok, owner}
    end

    test "Agents (GenServers) spawned from an owner resolve via $ancestors" do
      :ok = Enclave.start_owner()
      owner = self()

      {:ok, pid} = Agent.start_link(fn -> :ok end)
      assert Enclave.owner(pid) == {:ok, owner}
      Agent.stop(pid)
    end

    test "processes spawned from an allowed process inherit the owner transitively" do
      test_pid = self()
      :ok = Enclave.start_owner()
      owner = self()

      {:ok, worker} = Agent.start(fn -> :ok end)
      :ok = Enclave.allow(owner, worker)

      # A Task spawned by the *worker* should resolve through the worker's
      # $callers back to the worker, which is allowed under `owner`.
      Agent.get(worker, fn _ ->
        t = Task.async(fn -> Enclave.owner(self()) end)
        send(test_pid, {:resolved, Task.await(t)})
      end)

      assert_receive {:resolved, {:ok, ^owner}}
      Agent.stop(worker)
    end

    test "a bare spawned process with no ancestry to any owner is :no_owner" do
      parent = self()

      pid =
        spawn(fn ->
          receive do
            {:check, from} -> send(from, {:result, Enclave.owner(self())})
          end
        end)

      send(pid, {:check, parent})
      assert_receive {:result, :no_owner}
    end
  end

  describe "deliverable?/2" do
    test "same-owner pair is deliverable" do
      :ok = Enclave.start_owner()
      parent = self()

      task =
        Task.async(fn ->
          send(parent, {:pid, self()})

          receive do
            :done -> :ok
          end
        end)

      assert_receive {:pid, child}
      assert Enclave.deliverable?(parent, child)
      send(child, :done)
      Task.await(task)
    end

    test "cross-owner pair is not deliverable" do
      test_pid = self()

      {:ok, owner_a} =
        Task.start(fn ->
          :ok = Enclave.start_owner()
          send(test_pid, {:a, self()})

          receive do
            :stop -> :ok
          end
        end)

      {:ok, owner_b} =
        Task.start(fn ->
          :ok = Enclave.start_owner()
          send(test_pid, {:b, self()})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:a, ^owner_a}
      assert_receive {:b, ^owner_b}

      refute Enclave.deliverable?(owner_a, owner_b)
      refute Enclave.deliverable?(owner_b, owner_a)

      send(owner_a, :stop)
      send(owner_b, :stop)
    end

    test "two unowned processes are deliverable (production path)" do
      {:ok, a} = Agent.start(fn -> :ok end)
      {:ok, b} = Agent.start(fn -> :ok end)

      assert Enclave.deliverable?(a, b)

      Agent.stop(a)
      Agent.stop(b)
    end

    test "owned publisher cannot deliver to unowned subscriber" do
      :ok = Enclave.start_owner()
      owner = self()

      # Plain spawn/1 does not set $ancestors or $callers, so this process
      # is genuinely unowned regardless of who spawned it.
      unowned = spawn(fn -> Process.sleep(:infinity) end)

      refute Enclave.deliverable?(owner, unowned)
      Process.exit(unowned, :kill)
    end

    test "unowned publisher cannot deliver to owned subscriber" do
      test_pid = self()

      {:ok, owner_pid} =
        Task.start(fn ->
          :ok = Enclave.start_owner()
          send(test_pid, :ready)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :ready
      {:ok, unowned} = Agent.start(fn -> :ok end)

      refute Enclave.deliverable?(unowned, owner_pid)

      send(owner_pid, :stop)
      Agent.stop(unowned)
    end
  end
end
