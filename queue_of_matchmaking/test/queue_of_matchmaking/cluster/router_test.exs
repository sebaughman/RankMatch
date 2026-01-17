defmodule QueueOfMatchmaking.Cluster.RouterTest do
  use ExUnit.Case, async: false

  alias QueueOfMatchmaking.Cluster.Router
  alias QueueOfMatchmaking.Cluster.AssignmentCoordinator

  setup do
    # Wait for system to be fully ready
    QueueOfMatchmaking.TestHelpers.wait_for_system_ready()
    :ok
  end

  describe "route_with_epoch/1 - basic functionality" do
    test "returns epoch 1" do
      {:ok, route} = Router.route_with_epoch(500)
      assert route.epoch == 1
    end

    test "returns stable shape with expected keys" do
      {:ok, route} = Router.route_with_epoch(500)
      assert Map.keys(route) |> Enum.sort() == [:epoch, :node, :partition_id]
    end

    test "succeeds for rank 0" do
      assert {:ok, _route} = Router.route_with_epoch(0)
    end

    test "succeeds for rank 10000" do
      assert {:ok, _route} = Router.route_with_epoch(10_000)
    end

    test "returns error for negative rank" do
      assert {:error, :invalid_rank} = Router.route_with_epoch(-1)
    end

    test "returns error for rank above max" do
      assert {:error, :invalid_rank} = Router.route_with_epoch(10_001)
    end

    test "returns error for non-integer rank" do
      assert {:error, :invalid_rank} = Router.route_with_epoch("500")
    end
  end

  describe "route_with_epoch/1 - multi-partition routing" do
    test "routes rank 0 to first partition" do
      {:ok, route} = Router.route_with_epoch(0)
      assert route.partition_id == "p-00000-00499"
    end

    test "routes rank 499 to first partition" do
      {:ok, route} = Router.route_with_epoch(499)
      assert route.partition_id == "p-00000-00499"
    end

    test "routes rank 500 to second partition" do
      {:ok, route} = Router.route_with_epoch(500)
      assert route.partition_id == "p-00500-00999"
    end

    test "routes rank 999 to second partition" do
      {:ok, route} = Router.route_with_epoch(999)
      assert route.partition_id == "p-00500-00999"
    end

    test "routes rank 5000 to middle partition" do
      {:ok, route} = Router.route_with_epoch(5000)
      assert route.partition_id == "p-05000-05499"
    end

    test "routes rank 10000 to last partition" do
      {:ok, route} = Router.route_with_epoch(10_000)
      assert route.partition_id == "p-09500-10000"
    end

    test "routes rank 9500 to last partition" do
      {:ok, route} = Router.route_with_epoch(9500)
      assert route.partition_id == "p-09500-10000"
    end
  end

  describe "route_with_epoch/1 - coordinator integration" do
    test "uses coordinator snapshot for routing table" do
      # Router should have been initialized with coordinator snapshot
      snapshot = AssignmentCoordinator.snapshot()

      # Verify routing uses assignments from snapshot
      assert length(snapshot.assignments) == 20

      # Test routing to each partition
      for assignment <- snapshot.assignments do
        rank = assignment.range_start
        {:ok, route} = Router.route_with_epoch(rank)
        assert route.partition_id == assignment.partition_id
        assert route.node == assignment.node
      end
    end

    test "routing table contains all 20 partitions" do
      snapshot = AssignmentCoordinator.snapshot()
      partition_ids = Enum.map(snapshot.assignments, & &1.partition_id)

      # Route to start of each partition and verify we get all unique partition_ids
      routed_partitions =
        snapshot.assignments
        |> Enum.map(fn assignment ->
          {:ok, route} = Router.route_with_epoch(assignment.range_start)
          route.partition_id
        end)
        |> Enum.uniq()

      assert length(routed_partitions) == 20
      assert Enum.sort(routed_partitions) == Enum.sort(partition_ids)
    end
  end

  describe "route_with_epoch/1 - epoch consistency" do
    test "routing fails on forced epoch mismatch" do
      # Configure fake coordinator that returns epoch 2
      Application.put_env(
        :queue_of_matchmaking,
        :assignment_coordinator_module,
        FakeCoordinatorEpoch2
      )

      # Router was initialized with epoch 1, coordinator now returns epoch 2
      assert {:error, :stale_routing_snapshot} = Router.route_with_epoch(500)

      # Cleanup
      Application.delete_env(:queue_of_matchmaking, :assignment_coordinator_module)
    end
  end

  describe "route_with_epoch/1 - error cases" do
    test "returns error when routing table is empty" do
      # Erase the routing table to simulate empty state
      :persistent_term.erase(:routing_table)

      assert {:error, :no_partition} = Router.route_with_epoch(500)
    end
  end

  describe "snapshot updates" do
    test "routing rebuilds on assignments_updated event" do
      # Get initial snapshot
      initial_snapshot = AssignmentCoordinator.snapshot()
      initial_computed_at = initial_snapshot.computed_at_ms

      # Wait a bit to ensure timestamp changes
      Process.sleep(10)

      # Trigger refresh which broadcasts assignments_updated
      AssignmentCoordinator.refresh()

      # Wait for Router to process the message
      Process.sleep(50)

      # Verify routing still works (table was rebuilt)
      {:ok, route} = Router.route_with_epoch(500)
      assert route.epoch == 1
      assert route.partition_id == "p-00500-00999"

      # Verify new snapshot has different timestamp
      new_snapshot = AssignmentCoordinator.snapshot()
      assert new_snapshot.computed_at_ms > initial_computed_at
    end
  end

  describe "no regression in routing behavior" do
    test "all valid ranks route successfully" do
      # Test sample of ranks across the range
      test_ranks = [0, 1, 100, 499, 500, 999, 1000, 5000, 9499, 9500, 9999, 10_000]

      for rank <- test_ranks do
        assert {:ok, route} = Router.route_with_epoch(rank)
        assert route.epoch == 1
        assert is_binary(route.partition_id)
        assert is_atom(route.node)
      end
    end

    test "invalid ranks return appropriate errors" do
      invalid_ranks = [-1, -100, 10_001, 20_000]

      for rank <- invalid_ranks do
        assert {:error, :invalid_rank} = Router.route_with_epoch(rank)
      end
    end
  end
end

defmodule FakeCoordinatorEpoch2 do
  @moduledoc false
  # Fake coordinator for testing epoch mismatch

  def current_epoch, do: 2

  def snapshot do
    %{
      epoch: 2,
      spec: %{rank_min: 0, rank_max: 10_000, partition_count: 20},
      nodes: [node()],
      assignments: [],
      computed_at_ms: System.monotonic_time(:millisecond)
    }
  end
end
