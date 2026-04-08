defmodule Enclave.DispatcherTest do
  # NOT async: these tests start/stop owners across processes and broadcast
  # on a shared PubSub instance. Running in parallel would let tests see each
  # other's messages, which is exactly the bug Enclave exists to fix — but we
  # can't depend on the fix to test the fix.
  use ExUnit.Case, async: false

  @pubsub Enclave.TestPubSub

  defp subscribe(topic), do: :ok = Phoenix.PubSub.subscribe(@pubsub, topic)

  defp broadcast(topic, msg) do
    Phoenix.PubSub.broadcast(@pubsub, topic, msg, Enclave.Dispatcher)
  end

  defp local_broadcast(topic, msg) do
    Phoenix.PubSub.local_broadcast(@pubsub, topic, msg, Enclave.Dispatcher)
  end

  setup do
    # Clean any prior owner state for this test process.
    _ = Enclave.stop_owner()
    :ok
  end

  describe "same-owner delivery" do
    test "a subscriber in the same owner receives the broadcast" do
      :ok = Enclave.start_owner()
      subscribe("topic:1")

      broadcast("topic:1", :hello)
      assert_receive :hello

      :ok = Enclave.stop_owner()
    end

    test "local_broadcast with Enclave dispatcher delivers within same owner" do
      :ok = Enclave.start_owner()
      subscribe("topic:local")

      local_broadcast("topic:local", :local_hello)
      assert_receive :local_hello

      :ok = Enclave.stop_owner()
    end

    test "a Task spawned from the owner receives the broadcast" do
      :ok = Enclave.start_owner()
      parent = self()

      task =
        Task.async(fn ->
          subscribe("topic:task")
          send(parent, :subscribed)

          receive do
            msg -> msg
          end
        end)

      assert_receive :subscribed
      broadcast("topic:task", :for_task)
      assert Task.await(task) == :for_task

      :ok = Enclave.stop_owner()
    end
  end

  describe "cross-owner isolation" do
    test "a subscriber in a different owner does NOT receive the broadcast" do
      test_pid = self()
      topic = "topic:cross-#{System.unique_integer([:positive])}"

      # Owner B: starts, subscribes, then waits. Broadcast will be sent from
      # the test process (Owner A) and should NOT reach B.
      {:ok, b} =
        Task.start(fn ->
          :ok = Enclave.start_owner()
          subscribe(topic)
          send(test_pid, :b_ready)

          receive do
            msg -> send(test_pid, {:b_got, msg})
          after
            200 -> send(test_pid, :b_timeout)
          end
        end)

      assert_receive :b_ready

      :ok = Enclave.start_owner()
      broadcast(topic, :should_not_arrive)

      # B should time out, not receive the message.
      assert_receive :b_timeout, 500
      refute_received {:b_got, _}

      # Cleanup
      Process.exit(b, :kill)
      :ok = Enclave.stop_owner()
    end
  end

  describe "unowned production path" do
    test "broadcast between two unowned processes still delivers" do
      test_pid = self()
      topic = "topic:unowned-#{System.unique_integer([:positive])}"

      {:ok, subscriber} =
        Task.start(fn ->
          subscribe(topic)
          send(test_pid, :ready)

          receive do
            msg -> send(test_pid, {:got, msg})
          end
        end)

      assert_receive :ready

      # Broadcast from another unowned process.
      {:ok, _} =
        Task.start(fn ->
          broadcast(topic, :prod_message)
        end)

      assert_receive {:got, :prod_message}, 500

      Process.exit(subscriber, :kill)
    end
  end

  describe "broadcast_from" do
    test "broadcast_from/4 filters based on the explicit from pid's owner" do
      :ok = Enclave.start_owner()
      subscribe("topic:from")

      # broadcast_from with self() as the from pid; we are the owner, so
      # our own subscription is excluded (default PubSub semantics) but
      # another subscriber in our owner would get it.
      :ok = Phoenix.PubSub.broadcast_from(@pubsub, self(), "topic:from", :skip_me, Enclave.Dispatcher)

      refute_receive :skip_me, 100

      :ok = Enclave.stop_owner()
    end
  end
end
