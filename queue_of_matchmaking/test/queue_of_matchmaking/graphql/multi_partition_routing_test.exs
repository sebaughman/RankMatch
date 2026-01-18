defmodule QueueOfMatchmaking.Graphql.MultiPartitionRoutingTest do
  @moduledoc """
  Tests for multi-partition routing correctness.
  Verifies Phase 4.8: routing to correct partitions across boundaries.
  """

  use ExUnit.Case, async: false
  import QueueOfMatchmaking.GraphqlCase

  setup do
    :ok = Application.stop(:queue_of_matchmaking)
    {:ok, _} = Application.ensure_all_started(:queue_of_matchmaking)
    QueueOfMatchmaking.TestHelpers.wait_for_system_ready()
    :ok
  end

  describe "routing correctness at boundaries" do
    test "routes to correct partition for boundary ranks" do
      boundary_ranks = [0, 1, 499, 500, 999, 1000, 9500, 9999, 10_000]

      Enum.each(boundary_ranks, fn rank ->
        user_a = unique_user_id("boundary_#{rank}_a")
        user_b = unique_user_id("boundary_#{rank}_b")

        {_socket_a, sub_id_a} = subscribe_to_match(user_a)
        {_socket_b, sub_id_b} = subscribe_to_match(user_b)

        assert_request_ok(add_request(user_a, rank))
        assert_request_ok(add_request(user_b, rank))

        users_a = assert_match_received(sub_id_a, 500)
        _users_b = assert_match_received(sub_id_b, 500)

        matched_ids = extract_user_ids(users_a)
        assert matched_ids == Enum.sort([user_a, user_b]),
               "Failed to match users at rank #{rank}"
      end)
    end

    test "users at partition boundaries route to different partitions" do
      user_499 = unique_user_id("boundary_499")
      user_500 = unique_user_id("boundary_500")

      {_socket_499, _sub_id_499} = subscribe_to_match(user_499)
      {_socket_500, _sub_id_500} = subscribe_to_match(user_500)

      assert_request_ok(add_request(user_499, 499))
      assert_request_ok(add_request(user_500, 500))

      refute_match_received(100)

      {:ok, route_499} = QueueOfMatchmaking.Cluster.Router.route_with_epoch(499)
      {:ok, route_500} = QueueOfMatchmaking.Cluster.Router.route_with_epoch(500)

      assert route_499.partition_id != route_500.partition_id,
             "Ranks 499 and 500 should be in different partitions"
    end

    test "routing table contains all 20 partitions" do
      {routing_epoch, table} = :persistent_term.get(:routing_table)

      assert routing_epoch == 1
      assert length(table) == 20

      ranges =
        Enum.map(table, fn partition ->
          {partition.range_start, partition.range_end}
        end)
        |> Enum.sort()

      assert hd(ranges) == {0, 499}
      assert List.last(ranges) == {9500, 10_000}

      Enum.each(table, fn partition ->
        assert partition.epoch == 1
        assert partition.partition_id =~ ~r/^p-\d{5}-\d{5}$/
      end)
    end
  end

  describe "all partitions created" do
    test "all 20 partitions are registered on single node" do
      expected_partitions =
        Enum.map(0..19, fn i ->
          range_start = i * 500
          range_end = if i == 19, do: 10_000, else: (i + 1) * 500 - 1

          "p-#{String.pad_leading(to_string(range_start), 5, "0")}-#{String.pad_leading(to_string(range_end), 5, "0")}"
        end)

      registered_partitions =
        Enum.map(expected_partitions, fn partition_id ->
          case QueueOfMatchmaking.Horde.Registry.lookup({:partition, 1, partition_id}) do
            [{pid, _}] when is_pid(pid) -> {partition_id, :ok}
            [] -> {partition_id, :missing}
          end
        end)

      missing =
        Enum.filter(registered_partitions, fn {_id, status} -> status == :missing end)
        |> Enum.map(fn {id, _} -> id end)

      assert Enum.empty?(missing),
             "Missing partitions: #{inspect(missing)}"

      assert length(registered_partitions) == 20
    end

    test "partition IDs are unique" do
      {_epoch, table} = :persistent_term.get(:routing_table)

      partition_ids = Enum.map(table, & &1.partition_id)
      unique_ids = Enum.uniq(partition_ids)

      assert length(partition_ids) == length(unique_ids),
             "Duplicate partition IDs found"
    end

    test "ranges cover 0-10000 completely without gaps" do
      {_epoch, table} = :persistent_term.get(:routing_table)

      sorted_partitions = Enum.sort_by(table, & &1.range_start)

      Enum.reduce(sorted_partitions, 0, fn partition, expected_start ->
        assert partition.range_start == expected_start,
               "Gap detected: expected start #{expected_start}, got #{partition.range_start}"

        partition.range_end + 1
      end)

      last_partition = List.last(sorted_partitions)
      assert last_partition.range_end == 10_000
    end
  end

end
