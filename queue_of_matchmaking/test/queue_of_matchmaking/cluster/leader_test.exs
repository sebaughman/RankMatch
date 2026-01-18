defmodule QueueOfMatchmaking.Cluster.LeaderTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.Cluster.Leader

  describe "leader_node/1" do
    test "returns minimum node from sorted list" do
      assert Leader.leader_node([:"a@host", :"b@host"]) == :"a@host"
    end

    test "returns minimum node from unsorted list" do
      assert Leader.leader_node([:"z@host", :"a@host", :"m@host"]) == :"a@host"
    end

    test "returns single node when list has one element" do
      assert Leader.leader_node([:"single@host"]) == :"single@host"
    end

    test "returns error for empty list" do
      assert Leader.leader_node([]) == nil
    end

    test "is deterministic - same input produces same output" do
      nodes = [:"c@host", :"a@host", :"b@host"]
      result1 = Leader.leader_node(nodes)
      result2 = Leader.leader_node(nodes)
      assert result1 == result2
      assert result1 == :"a@host"
    end
  end

  describe "leader_node/0" do
    test "returns current node when running single node" do
      # In test environment, typically only one node
      result = Leader.leader_node()
      assert result == node()
    end
  end

  describe "am_leader?/1" do
    test "returns true when current node is minimum" do
      # Current node should sort first
      nodes = [node(), :"zzz@host"]
      assert Leader.am_leader?(nodes) == true
    end

    test "returns false when current node is not minimum" do
      # Current node should not sort first
      nodes = [node(), :"aaa@host"]
      assert Leader.am_leader?(nodes) == false
    end

    test "returns true for single node list containing current node" do
      assert Leader.am_leader?([node()]) == true
    end

    test "returns error for empty list" do
      assert Leader.am_leader?([]) == false
    end
  end

  describe "am_leader?/0" do
    test "returns boolean for current cluster state" do
      # Should return true in single-node test environment
      result = Leader.am_leader?()
      assert is_boolean(result)
      assert result == true
    end
  end
end
