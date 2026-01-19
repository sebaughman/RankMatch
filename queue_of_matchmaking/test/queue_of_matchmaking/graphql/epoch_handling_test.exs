defmodule QueueOfMatchmaking.Graphql.EpochHandlingTest do
  @moduledoc """
  Tests for epoch-carrying resolver flow and stale epoch handling.
  """

  use ExUnit.Case, async: false
  import QueueOfMatchmaking.GraphqlCase

  setup do
    :ok = Application.stop(:queue_of_matchmaking)
    {:ok, _} = Application.ensure_all_started(:queue_of_matchmaking)
    QueueOfMatchmaking.TestHelpers.wait_for_system_ready()
    :ok
  end

  describe "epoch propagation" do
    test "resolver successfully enqueues request through epoch-aware flow" do
      user_id = unique_user_id("epoch_check")

      assert_request_ok(add_request(user_id, 1000))
    end

    test "Router returns epoch in route_with_epoch" do
      result = QueueOfMatchmaking.Cluster.Router.route_with_epoch(1000)

      assert {:ok, route} = result
      assert route.epoch == 1
      assert route.partition_id =~ "p-"
      assert is_atom(route.node)
    end

    test "all partitions are registered with epoch-scoped keys" do
      partitions =
        Enum.map(0..19, fn i ->
          range_start = i * 500
          range_end = if i == 19, do: 10_000, else: (i + 1) * 500 - 1

          partition_id =
            "p-#{String.pad_leading(to_string(range_start), 5, "0")}-#{String.pad_leading(to_string(range_end), 5, "0")}"

          QueueOfMatchmaking.Horde.Registry.lookup({:partition, 1, partition_id})
        end)

      assert Enum.all?(partitions, fn
               [{pid, _}] when is_pid(pid) -> true
               _ -> false
             end),
             "Not all partitions registered with epoch 1"
    end
  end

end
