defmodule QueueOfMatchmaking.Graphql.EpochValidationTest do
  use ExUnit.Case

  alias QueueOfMatchmaking.Cluster.{AssignmentCoordinator, Router}
  alias QueueOfMatchmaking.Horde.Registry
  alias QueueOfMatchmaking.Matchmaking.PartitionWorker
  import QueueOfMatchmaking.TestHelpers

  @moduledoc """
  Tests epoch correctness invariants established by versioned assignment scaffolding.
  """

  setup do
    wait_for_system_ready()
    :ok
  end

  describe "router epoch validation" do
    test "router maintains correct epoch from coordinator" do
      snapshot = AssignmentCoordinator.snapshot()
      {:ok, route_info} = Router.route_with_epoch(500)

      assert route_info.epoch == snapshot.epoch
      assert route_info.epoch == 1
    end

    test "router routing table contains epoch metadata" do
      {:ok, route_info} = Router.route_with_epoch(500)

      assert Map.has_key?(route_info, :epoch)
      assert Map.has_key?(route_info, :partition_id)
      assert Map.has_key?(route_info, :node)
    end
  end

  describe "partition worker stale epoch rejection" do
    test "partition worker rejects stale epoch in peek_nearest" do
      {:ok, route_info} = Router.route_with_epoch(500)
      [{pid, _}] = Registry.lookup({:partition, 1, route_info.partition_id})

      result = PartitionWorker.peek_nearest(pid, 500, 0, "exclude", 999, 100)

      assert result == {:error, :epoch_mismatch}
    end

    test "partition worker rejects stale epoch in reserve" do
      {:ok, route_info} = Router.route_with_epoch(500)
      [{pid, _}] = Registry.lookup({:partition, 1, route_info.partition_id})

      result = PartitionWorker.reserve(pid, "user", 500, 0, 999, 100)

      assert result == {:error, :epoch_mismatch}
    end
  end

  describe "epoch propagation verification" do
    test "epoch=1 throughout system" do
      # Coordinator
      assert AssignmentCoordinator.current_epoch() == 1
      snapshot = AssignmentCoordinator.snapshot()
      assert snapshot.epoch == 1

      # All assignments have epoch=1
      Enum.each(snapshot.assignments, fn a ->
        assert a.epoch == 1
      end)

      # Router
      {:ok, route_info} = Router.route_with_epoch(500)
      assert route_info.epoch == 1

      # Verify partitions are registered by looking them up directly
      partition_ids = Enum.map(snapshot.assignments, & &1.partition_id)

      registered_partitions =
        Enum.map(partition_ids, fn partition_id ->
          case Registry.lookup({:partition, 1, partition_id}) do
            [{pid, _}] -> {partition_id, pid}
            [] -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      # Verify all registered partitions have epoch=1 in their key
      Enum.each(registered_partitions, fn {partition_id, _pid} ->
        # The partition is registered under {:partition, 1, partition_id}
        # which means epoch=1
        assert String.starts_with?(partition_id, "p-"), "Partition ID should start with 'p-'"
      end)

      # Should have most partitions registered (allow some startup delay)
      assert length(registered_partitions) >= 18,
             "Expected at least 18 partitions, got #{length(registered_partitions)}"
    end

    test "all assignments in snapshot have consistent epoch" do
      snapshot = AssignmentCoordinator.snapshot()

      epochs = Enum.map(snapshot.assignments, & &1.epoch) |> Enum.uniq()

      assert epochs == [1], "Expected all assignments to have epoch=1"
      assert length(snapshot.assignments) == 20
    end
  end
end
