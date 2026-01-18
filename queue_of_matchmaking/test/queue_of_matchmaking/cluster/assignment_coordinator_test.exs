defmodule QueueOfMatchmaking.Cluster.AssignmentCoordinatorTest do
  use ExUnit.Case, async: false

  alias QueueOfMatchmaking.Cluster.AssignmentCoordinator

  setup do
    # Start the coordinator if not already started
    case GenServer.whereis(AssignmentCoordinator) do
      nil ->
        {:ok, pid} = start_supervised(AssignmentCoordinator)
        {:ok, coordinator: pid}

      pid ->
        {:ok, coordinator: pid}
    end
  end

  describe "snapshot/0" do
    test "returns snapshot with epoch 1" do
      snapshot = AssignmentCoordinator.snapshot()
      assert snapshot.epoch == 1
    end

    test "snapshot includes spec with expected fields" do
      snapshot = AssignmentCoordinator.snapshot()

      assert snapshot.spec.rank_min == 0
      assert snapshot.spec.rank_max == 10_000
      assert snapshot.spec.partition_count == 20
    end

    test "snapshot includes sorted nodes list" do
      snapshot = AssignmentCoordinator.snapshot()

      assert is_list(snapshot.nodes)
      assert snapshot.nodes == Enum.sort(snapshot.nodes)
      assert node() in snapshot.nodes
    end

    test "snapshot includes assignments list" do
      snapshot = AssignmentCoordinator.snapshot()

      assert is_list(snapshot.assignments)
      assert length(snapshot.assignments) > 0
    end

    test "snapshot includes computed_at_ms timestamp" do
      snapshot = AssignmentCoordinator.snapshot()

      assert is_integer(snapshot.computed_at_ms)
      # Monotonic time can be negative, just verify it's an integer
    end
  end

  describe "assignments/0" do
    test "all assignments include epoch 1" do
      assignments = AssignmentCoordinator.assignments()

      assert Enum.all?(assignments, fn assignment ->
               assignment.epoch == 1
             end)
    end

    test "assignments have required fields" do
      assignments = AssignmentCoordinator.assignments()

      assert Enum.all?(assignments, fn assignment ->
               Map.has_key?(assignment, :epoch) and
                 Map.has_key?(assignment, :partition_id) and
                 Map.has_key?(assignment, :range_start) and
                 Map.has_key?(assignment, :range_end) and
                 Map.has_key?(assignment, :node)
             end)
    end
  end

  describe "current_epoch/0" do
    test "returns epoch 1" do
      assert AssignmentCoordinator.current_epoch() == 1
    end
  end

  describe "spec/0" do
    test "returns spec map" do
      spec = AssignmentCoordinator.spec()

      assert spec.rank_min == 0
      assert spec.rank_max == 10_000
      assert spec.partition_count == 20
    end
  end

  describe "nodes/0" do
    test "returns sorted node list" do
      nodes = AssignmentCoordinator.nodes()

      assert is_list(nodes)
      assert nodes == Enum.sort(nodes)
      assert node() in nodes
    end
  end

  describe "determinism" do
    test "calling snapshot twice returns same assignments" do
      snapshot1 = AssignmentCoordinator.snapshot()
      snapshot2 = AssignmentCoordinator.snapshot()

      # Assignments should be identical (same epoch, nodes, ranges)
      assert snapshot1.epoch == snapshot2.epoch
      assert snapshot1.spec == snapshot2.spec
      assert snapshot1.nodes == snapshot2.nodes
      assert snapshot1.assignments == snapshot2.assignments
    end
  end

  describe "refresh/0" do
    test "updates computed_at_ms timestamp" do
      snapshot1 = AssignmentCoordinator.snapshot()
      original_timestamp = snapshot1.computed_at_ms

      # Small delay to ensure monotonic time advances
      Process.sleep(10)

      :ok = AssignmentCoordinator.refresh()
      snapshot2 = AssignmentCoordinator.snapshot()

      assert snapshot2.computed_at_ms > original_timestamp
    end

    test "maintains epoch and spec after refresh" do
      snapshot1 = AssignmentCoordinator.snapshot()

      :ok = AssignmentCoordinator.refresh()
      snapshot2 = AssignmentCoordinator.snapshot()

      assert snapshot1.epoch == snapshot2.epoch
      assert snapshot1.spec == snapshot2.spec
    end

    test "returns :ok" do
      assert AssignmentCoordinator.refresh() == :ok
    end
  end

  describe "PubSub broadcast" do
    test "broadcasts on init" do
      # Subscribe before starting a new coordinator
      AssignmentCoordinator.subscribe()

      # Trigger a refresh to get a broadcast
      AssignmentCoordinator.refresh()

      assert_receive {:assignments_updated, snapshot}, 1000
      assert snapshot.epoch == 1
      assert is_list(snapshot.assignments)
    end

    test "broadcasts on refresh" do
      AssignmentCoordinator.subscribe()

      AssignmentCoordinator.refresh()

      assert_receive {:assignments_updated, snapshot}, 1000
      assert snapshot.epoch == 1
    end
  end

  describe "leader-gated broadcast" do
    test "leader node broadcasts assignments_updated on refresh" do
      # In single-node test environment, current node is always leader
      AssignmentCoordinator.subscribe()

      :ok = AssignmentCoordinator.refresh()

      # Leader should broadcast
      assert_receive {:assignments_updated, snapshot}, 1000
      assert snapshot.epoch == 1
      assert is_list(snapshot.assignments)
      assert length(snapshot.assignments) == 20
    end

    test "broadcast message contains complete snapshot structure" do
      AssignmentCoordinator.subscribe()

      AssignmentCoordinator.refresh()

      assert_receive {:assignments_updated, snapshot}, 1000

      # Verify snapshot has all required fields
      assert Map.has_key?(snapshot, :epoch)
      assert Map.has_key?(snapshot, :spec)
      assert Map.has_key?(snapshot, :nodes)
      assert Map.has_key?(snapshot, :assignments)
      assert Map.has_key?(snapshot, :computed_at_ms)

      # Verify spec structure
      assert snapshot.spec.rank_min == 0
      assert snapshot.spec.rank_max == 10_000
      assert snapshot.spec.partition_count == 20
    end

    test "snapshot is updated locally regardless of broadcast" do
      # Even if broadcast is gated, local snapshot should always update
      snapshot_before = AssignmentCoordinator.snapshot()
      timestamp_before = snapshot_before.computed_at_ms

      Process.sleep(10)

      :ok = AssignmentCoordinator.refresh()

      snapshot_after = AssignmentCoordinator.snapshot()
      timestamp_after = snapshot_after.computed_at_ms

      # Snapshot should be updated locally
      assert timestamp_after > timestamp_before
      assert snapshot_after.epoch == snapshot_before.epoch
    end

    test "multiple rapid refreshes each trigger broadcast (no debounce at coordinator level)" do
      AssignmentCoordinator.subscribe()

      # Trigger multiple rapid refreshes
      AssignmentCoordinator.refresh()
      AssignmentCoordinator.refresh()
      AssignmentCoordinator.refresh()

      # Should receive 3 broadcasts (coordinator doesn't debounce)
      assert_receive {:assignments_updated, _}, 1000
      assert_receive {:assignments_updated, _}, 1000
      assert_receive {:assignments_updated, _}, 1000
    end
  end

  describe "subscribe/0" do
    test "returns :ok" do
      assert AssignmentCoordinator.subscribe() == :ok
    end

    test "allows receiving assignment updates" do
      AssignmentCoordinator.subscribe()

      AssignmentCoordinator.refresh()

      assert_receive {:assignments_updated, _snapshot}, 1000
    end
  end
end
