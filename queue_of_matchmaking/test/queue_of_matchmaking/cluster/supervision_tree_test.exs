defmodule QueueOfMatchmaking.Cluster.SupervisionTreeTest do
  @moduledoc """
  Tests for supervision tree ordering and startup safety.
  Verifies Phase 4.6: epoch-safe supervision ordering.
  """

  use ExUnit.Case, async: false
  import QueueOfMatchmaking.GraphqlCase

  setup do
    :ok = Application.stop(:queue_of_matchmaking)
    {:ok, _} = Application.ensure_all_started(:queue_of_matchmaking)
    :ok
  end

  describe "supervision tree startup safety" do
    test "system starts and becomes ready for requests" do
      :ok = Application.stop(:queue_of_matchmaking)
      {:ok, _} = Application.ensure_all_started(:queue_of_matchmaking)

      QueueOfMatchmaking.TestHelpers.wait_for_system_ready()

      user_id = unique_user_id("after_ready")
      assert_request_ok(add_request(user_id, 1000))
    end

    test "Router waits for valid snapshot before routing" do
      :ok = Application.stop(:queue_of_matchmaking)
      {:ok, _} = Application.ensure_all_started(:queue_of_matchmaking)

      QueueOfMatchmaking.TestHelpers.wait_for_system_ready()

      result = QueueOfMatchmaking.Cluster.Router.route_with_epoch(500)

      assert {:ok, route} = result
      assert route.epoch == 1
      assert route.partition_id =~ "p-"
      assert is_atom(route.node)
    end

    test "PartitionManager starts all partitions before Router routes" do
      :ok = Application.stop(:queue_of_matchmaking)
      {:ok, _} = Application.ensure_all_started(:queue_of_matchmaking)

      QueueOfMatchmaking.TestHelpers.wait_for_system_ready()

      partitions =
        Enum.map(0..19, fn i ->
          range_start = i * 500
          range_end = if i == 19, do: 10_000, else: (i + 1) * 500 - 1
          partition_id = "p-#{String.pad_leading(to_string(range_start), 5, "0")}-#{String.pad_leading(to_string(range_end), 5, "0")}"

          case QueueOfMatchmaking.Horde.Registry.lookup({:partition, 1, partition_id}) do
            [{pid, _}] when is_pid(pid) -> :ok
            [] -> :missing
          end
        end)

      assert Enum.all?(partitions, &(&1 == :ok)),
             "Not all partitions registered: #{inspect(partitions)}"
    end
  end
end
