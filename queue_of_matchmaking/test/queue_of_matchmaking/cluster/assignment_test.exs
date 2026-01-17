defmodule QueueOfMatchmaking.Cluster.AssignmentTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.Cluster.Assignment
  alias QueueOfMatchmaking.Config

  @default_config Config.cluster_config()

  describe "compute_assignments/2" do
    test "returns empty list for empty node list" do
      assert [] = Assignment.compute_assignments([], @default_config)
    end

    test "assigns all partitions to single node" do
      nodes = [:node1@host]
      assignments = Assignment.compute_assignments(nodes, @default_config)

      assert length(assignments) == 20
      assert Enum.all?(assignments, fn a -> a.epoch == 1 and a.node == :node1@host end)
    end

    test "alternates partitions between two nodes" do
      nodes = [:node1@host, :node2@host]
      assignments = Assignment.compute_assignments(nodes, @default_config)

      assert length(assignments) == 20

      # Even indices go to node1, odd to node2
      Enum.with_index(assignments)
      |> Enum.each(fn {assignment, idx} ->
        expected_node = if rem(idx, 2) == 0, do: :node1@host, else: :node2@host
        assert assignment.epoch == 1
        assert assignment.node == expected_node
      end)
    end

    test "distributes partitions round-robin across three nodes" do
      nodes = [:node1@host, :node2@host, :node3@host]
      assignments = Assignment.compute_assignments(nodes, @default_config)

      assert length(assignments) == 20

      # Check distribution pattern
      assert Enum.at(assignments, 0).epoch == 1
      assert Enum.at(assignments, 0).node == :node1@host
      assert Enum.at(assignments, 1).node == :node2@host
      assert Enum.at(assignments, 2).node == :node3@host
      assert Enum.at(assignments, 3).node == :node1@host
    end

    test "first partition covers 0-499" do
      nodes = [:node1@host]
      assignments = Assignment.compute_assignments(nodes, @default_config)

      first = Enum.at(assignments, 0)
      assert first.epoch == 1
      assert first.range_start == 0
      assert first.range_end == 499
      assert first.partition_id == "p-00000-00499"
    end

    test "last partition covers 9500-10000 (inclusive)" do
      nodes = [:node1@host]
      assignments = Assignment.compute_assignments(nodes, @default_config)

      last = Enum.at(assignments, 19)
      assert last.epoch == 1
      assert last.range_start == 9500
      assert last.range_end == 10_000
      assert last.partition_id == "p-09500-10000"
    end

    test "partition IDs use zero-padded string format" do
      nodes = [:node1@host]
      assignments = Assignment.compute_assignments(nodes, @default_config)

      assert Enum.at(assignments, 0).epoch == 1
      assert Enum.at(assignments, 0).partition_id == "p-00000-00499"
      assert Enum.at(assignments, 1).partition_id == "p-00500-00999"
      assert Enum.at(assignments, 10).partition_id == "p-05000-05499"
    end

    test "all ranges are contiguous and non-overlapping" do
      nodes = [:node1@host]
      assignments = Assignment.compute_assignments(nodes, @default_config)

      assignments
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a1, a2] ->
        assert a2.range_start == a1.range_end + 1
      end)
    end

    test "deterministic assignment regardless of node order" do
      nodes1 = [:node2@host, :node1@host, :node3@host]
      nodes2 = [:node3@host, :node1@host, :node2@host]

      assignments1 = Assignment.compute_assignments(nodes1, @default_config)
      assignments2 = Assignment.compute_assignments(nodes2, @default_config)

      assert assignments1 == assignments2
    end

    test "covers full rank range from min to max" do
      nodes = [:node1@host]
      assignments = Assignment.compute_assignments(nodes, @default_config)

      first = Enum.at(assignments, 0)
      last = Enum.at(assignments, 19)

      assert first.epoch == 1
      assert first.range_start == 0
      assert last.epoch == 1
      assert last.range_end == 10_000
    end

    test "each assignment has all required fields" do
      nodes = [:node1@host]
      assignments = Assignment.compute_assignments(nodes, @default_config)

      Enum.each(assignments, fn assignment ->
        assert assignment.epoch == 1
        assert is_binary(assignment.partition_id)
        assert is_integer(assignment.range_start)
        assert is_integer(assignment.range_end)
        assert is_atom(assignment.node)
        assert assignment.range_start <= assignment.range_end
      end)
    end

    test "uses epoch from config when provided" do
      custom_config = Keyword.put(@default_config, :epoch, 42)
      nodes = [:node1@host]
      assignments = Assignment.compute_assignments(nodes, custom_config)

      assert length(assignments) == 20
      assert Enum.all?(assignments, fn a -> a.epoch == 42 end)
    end

    test "defaults to epoch 1 when not in config" do
      config_without_epoch = Keyword.delete(@default_config, :epoch)
      nodes = [:node1@host]
      assignments = Assignment.compute_assignments(nodes, config_without_epoch)

      assert Enum.all?(assignments, fn a -> a.epoch == 1 end)
    end
  end
end
