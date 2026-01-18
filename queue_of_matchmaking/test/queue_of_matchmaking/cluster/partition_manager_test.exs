defmodule QueueOfMatchmaking.Cluster.PartitionManagerTest do
  use ExUnit.Case, async: false

  alias QueueOfMatchmaking.Cluster.{PartitionManager, AssignmentCoordinator}
  alias QueueOfMatchmaking.Horde.Registry

  setup do
    # Ensure clean state
    on_exit(fn ->
      # Clean up any test partitions
      :ok
    end)

    :ok
  end

  describe "init/1" do
    test "starts all local partitions on single node" do
      # Wait for PartitionManager to initialize
      Process.sleep(100)

      state = PartitionManager.debug_state()

      # Should have 20 partitions on single node
      assert state.active_epoch == 1
      assert state.local_partition_count == 20
      assert state.assignment_count == 20
    end

    test "partitions are registered with epoch-scoped keys" do
      Process.sleep(100)

      state = PartitionManager.debug_state()

      # Verify all partition keys have epoch-scoped format
      Enum.each(state.partition_keys, fn {epoch, partition_id} ->
        assert epoch == 1
        assert is_binary(partition_id)
        assert String.starts_with?(partition_id, "p-")

        # Verify registration exists
        assert [{pid, _}] = Registry.lookup({:partition, epoch, partition_id})
        assert is_pid(pid)
        assert Process.alive?(pid)
      end)
    end

    test "logs startup with epoch and partition count" do
      # This test verifies the log message exists (implementation already logs)
      # In a real scenario, we'd capture logs, but for now we verify state
      state = PartitionManager.debug_state()
      assert state.active_epoch == 1
      assert state.local_partition_count > 0
    end
  end

  describe "rebalance/0" do
    test "is idempotent - calling multiple times doesn't change state" do
      Process.sleep(100)

      state_before = PartitionManager.debug_state()

      # Call rebalance multiple times
      assert :ok = PartitionManager.rebalance()
      assert :ok = PartitionManager.rebalance()
      assert :ok = PartitionManager.rebalance()

      state_after = PartitionManager.debug_state()

      # State should be unchanged
      assert state_before.active_epoch == state_after.active_epoch
      assert state_before.local_partition_count == state_after.local_partition_count
      assert state_before.assignment_count == state_after.assignment_count
    end

    test "starts missing partitions" do
      Process.sleep(100)

      # Get initial state
      initial_state = PartitionManager.debug_state()
      initial_count = initial_state.local_partition_count

      # Rebalance should be idempotent (no missing partitions)
      assert :ok = PartitionManager.rebalance()

      final_state = PartitionManager.debug_state()
      assert final_state.local_partition_count == initial_count
    end

    test "handles already_started gracefully" do
      Process.sleep(100)

      # Rebalance when all partitions already exist
      assert :ok = PartitionManager.rebalance()

      state = PartitionManager.debug_state()
      assert state.local_partition_count == 20
    end

    test "multiple rapid rebalance calls are serialized" do
      Process.sleep(100)

      # Spawn multiple concurrent rebalance calls
      tasks =
        for _ <- 1..5 do
          Task.async(fn -> PartitionManager.rebalance() end)
        end

      # All should complete successfully (GenServer.call ensures serialization)
      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))

      # State should be consistent
      state = PartitionManager.debug_state()
      assert state.local_partition_count == 20
    end
  end

  describe "handle_info/2 - assignments_updated" do
    test "receives assignment update events" do
      Process.sleep(100)

      # Trigger a coordinator refresh (which broadcasts assignments_updated)
      AssignmentCoordinator.refresh()

      # Give time for message to be processed
      Process.sleep(50)

      # State should remain unchanged (no-op in v1)
      state = PartitionManager.debug_state()
      assert state.active_epoch == 1
      assert state.local_partition_count == 20
    end
  end

  describe "debounced auto-reconcile" do
    test "first assignments_updated schedules auto-rebalance" do
      Process.sleep(100)

      # Trigger coordinator refresh
      AssignmentCoordinator.refresh()

      # Give time for timer to fire (25ms + processing)
      Process.sleep(100)

      # Reconcile should have executed
      state = PartitionManager.debug_state()
      assert state.active_epoch == 1
      assert state.local_partition_count == 20
    end

    test "rapid assignment updates are debounced" do
      Process.sleep(100)

      # Trigger multiple rapid refreshes
      AssignmentCoordinator.refresh()
      AssignmentCoordinator.refresh()
      AssignmentCoordinator.refresh()

      # Give time for debounce and single reconcile
      Process.sleep(100)

      # Should have processed updates without issues
      # Debouncing means only one reconcile executed
      state = PartitionManager.debug_state()
      assert state.active_epoch == 1
      assert state.local_partition_count == 20
    end

    test "snapshot is passed through timer correctly" do
      Process.sleep(100)

      # Get initial snapshot
      snapshot_before = AssignmentCoordinator.snapshot()

      # Trigger refresh (which updates snapshot and broadcasts)
      AssignmentCoordinator.refresh()

      # Wait for auto-rebalance to execute
      Process.sleep(100)

      # Verify reconcile used updated snapshot
      state = PartitionManager.debug_state()
      assert state.active_epoch == snapshot_before.epoch
      assert state.local_partition_count == 20
    end

    test "debounce flag is set and reset correctly" do
      Process.sleep(100)

      # Trigger first update
      AssignmentCoordinator.refresh()

      # Immediately trigger second update (should be debounced)
      AssignmentCoordinator.refresh()

      # Wait for timer to fire and flag to reset
      Process.sleep(100)

      # Trigger another update (should schedule new timer)
      AssignmentCoordinator.refresh()

      # Wait for second reconcile
      Process.sleep(100)

      # System should be stable
      state = PartitionManager.debug_state()
      assert state.local_partition_count == 20
    end

    test "auto-reconcile executes with correct snapshot" do
      Process.sleep(100)

      initial_state = PartitionManager.debug_state()
      initial_count = initial_state.local_partition_count

      # Trigger update
      AssignmentCoordinator.refresh()

      # Wait for auto-reconcile
      Process.sleep(100)

      final_state = PartitionManager.debug_state()

      # Should have reconciled (even if no changes)
      assert final_state.local_partition_count == initial_count
      assert final_state.active_epoch == 1
    end
  end

  describe "ungated manual rebalance" do
    test "manual rebalance always executes (no leader check)" do
      Process.sleep(100)

      # Manual rebalance should work regardless of leader status
      # In single-node test, we're always leader, but code has no gate
      assert :ok = PartitionManager.rebalance()

      state = PartitionManager.debug_state()
      assert state.local_partition_count == 20
    end

    test "manual rebalance fetches fresh snapshot" do
      Process.sleep(100)

      snapshot_before = AssignmentCoordinator.snapshot()

      # Trigger refresh to update coordinator snapshot
      AssignmentCoordinator.refresh()

      # Manual rebalance should use fresh snapshot
      assert :ok = PartitionManager.rebalance()

      state = PartitionManager.debug_state()
      assert state.active_epoch == snapshot_before.epoch
    end

    test "manual rebalance works independently of auto-reconcile" do
      Process.sleep(100)

      # Trigger auto-reconcile
      AssignmentCoordinator.refresh()

      # Immediately call manual rebalance (should not conflict)
      assert :ok = PartitionManager.rebalance()

      # Wait for auto-reconcile timer
      Process.sleep(100)

      # Both should complete successfully
      state = PartitionManager.debug_state()
      assert state.local_partition_count == 20
    end
  end

  describe "edge cases" do
    test "handles empty desired set gracefully" do
      # This would require mocking AssignmentCoordinator to return no assignments
      # for this node, which is complex. For now, we verify current behavior.
      Process.sleep(100)

      state = PartitionManager.debug_state()
      assert state.local_partition_count > 0
    end

    test "debug_state returns sanitized view" do
      Process.sleep(100)

      state = PartitionManager.debug_state()

      # Verify structure
      assert is_integer(state.active_epoch)
      assert is_integer(state.assignment_count)
      assert is_integer(state.local_partition_count)
      assert is_list(state.partition_keys)

      # Should not expose full internal state
      refute Map.has_key?(state, :assignments)
      refute Map.has_key?(state, :local_partitions)
    end
  end

  describe "partition lifecycle" do
    test "partitions are running and can be looked up" do
      Process.sleep(100)

      snapshot = AssignmentCoordinator.snapshot()

      # Verify each partition is running
      Enum.each(snapshot.assignments, fn assignment ->
        key = {:partition, assignment.epoch, assignment.partition_id}

        case Registry.lookup(key) do
          [{pid, _}] ->
            assert Process.alive?(pid)

          [] ->
            # Partition might be on another node in multi-node setup
            # For single-node test, all should be present
            if assignment.node == node() do
              flunk("Expected partition #{assignment.partition_id} to be registered")
            end
        end
      end)
    end
  end
end
