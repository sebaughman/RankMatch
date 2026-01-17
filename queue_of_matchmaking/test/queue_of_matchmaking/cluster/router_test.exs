defmodule QueueOfMatchmaking.Cluster.RouterTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.Cluster.Router

  describe "route_with_epoch/1" do
    test "returns epoch 1" do
      {:ok, route} = Router.route_with_epoch(500)
      assert route.epoch == 1
    end

    test "returns partition_id for full range" do
      {:ok, route} = Router.route_with_epoch(500)
      assert route.partition_id == "p-00000-10000"
    end

    test "returns current node" do
      {:ok, route} = Router.route_with_epoch(500)
      assert route.node == node()
    end

    test "returns stable shape with no extra keys" do
      {:ok, route} = Router.route_with_epoch(500)
      assert Map.keys(route) |> Enum.sort() == [:epoch, :node, :partition_id]
    end

    test "succeeds for rank 0" do
      assert {:ok, _route} = Router.route_with_epoch(0)
    end

    test "succeeds for rank 10000" do
      assert {:ok, _route} = Router.route_with_epoch(10_000)
    end

    test "succeeds for any rank in valid range" do
      for rank <- [0, 100, 1000, 5000, 9999, 10_000] do
        assert {:ok, route} = Router.route_with_epoch(rank)
        assert route.epoch == 1
        assert route.partition_id == "p-00000-10000"
        assert route.node == node()
      end
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
end
