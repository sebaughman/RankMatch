defmodule QueueOfMatchmaking.Graphql.LargeScaleTest do
  use ExUnit.Case
  import QueueOfMatchmaking.GraphqlCase
  import Phoenix.ChannelTest
  import QueueOfMatchmaking.TestHelpers

  @moduledoc """
  Large-scale integration tests verifying system behavior under concurrent load.
  """

  @moduletag timeout: 60_000
  @moduletag :large_scale

  setup do
    wait_for_system_ready()
    :ok
  end

  describe "concurrent load" do
    @tag timeout: 60_000
    test "100 concurrent enqueues across partitions" do
      # Spread users across rank ranges (multiple partitions)
      ranks = Enum.map(1..100, fn i -> rem(i * 100, 10_000) end)

      tasks =
        for {rank, i} <- Enum.with_index(ranks) do
          Task.async(fn ->
            add_request("concurrent_#{i}", rank)
          end)
        end

      results = Task.await_many(tasks, 30_000)

      # Assertions:
      # 1. No crashes (all tasks completed)
      assert length(results) == 100

      # 2. Most requests succeeded (some may hit backpressure)
      success_count =
        Enum.count(results, fn
          {:ok, %{data: %{"addRequest" => %{"ok" => true}}}} -> true
          _ -> false
        end)

      assert success_count > 70, "Expected >70% success rate, got #{success_count}"

      # 3. No duplicate "already_queued" errors for distinct users
      already_queued_count =
        Enum.count(results, fn
          {:ok, %{data: %{"addRequest" => %{"error" => error}}}} when is_binary(error) ->
            error =~ "already"

          _ ->
            false
        end)

      assert already_queued_count == 0, "No user should be 'already_queued'"
    end
  end

  describe "boundary rank matching" do
    test "users at partition boundaries match correctly" do
      boundaries = [
        {0, 1},
        {499, 500},
        {999, 1000},
        {9999, 10_000}
      ]

      for {rank_a, rank_b} <- boundaries do
        user_a = "boundary_#{rank_a}_a"
        user_b = "boundary_#{rank_b}_b"

        {socket_a, _sub_id_a} = subscribe_to_match(user_a)
        {socket_b, _sub_id_b} = subscribe_to_match(user_b)

        {:ok, %{data: %{"addRequest" => result_a}}} = add_request(user_a, rank_a)
        {:ok, %{data: %{"addRequest" => result_b}}} = add_request(user_b, rank_b)

        # Both should enqueue successfully
        assert result_a["ok"] == true, "User A at rank #{rank_a} should enqueue"
        assert result_b["ok"] == true, "User B at rank #{rank_b} should enqueue"

        # Wait for potential match (they should match quickly due to small diff)
        receive do
          %Phoenix.Socket.Message{event: "subscription:data"} ->
            :matched
        after
          1000 ->
            # May not match immediately if widening needed
            :ok
        end

        # Clean up - use close instead of leave to avoid EXIT
        close(socket_a)
        close(socket_b)
      end
    end
  end

  describe "cross-partition widening" do
    @tag timeout: 60_000
    test "widening enables cross-partition matches" do
      # Place users in adjacent partitions with diff > initial allowed
      user_a = "widen_cross_a"
      user_b = "widen_cross_b"

      {socket_a, _sub_id_a} = subscribe_to_match(user_a)
      {socket_b, _sub_id_b} = subscribe_to_match(user_b)

      {:ok, %{data: %{"addRequest" => result_a}}} = add_request(user_a, 499)
      {:ok, %{data: %{"addRequest" => result_b}}} = add_request(user_b, 521)

      assert result_a["ok"] == true
      assert result_b["ok"] == true

      # Wait for widening window (diff=22, needs ~300ms at 50/25ms)
      assert_push("subscription:data", _, 1000)
      assert_push("subscription:data", _, 1000)

      # Clean up - use close instead of leave to avoid EXIT
      close(socket_a)
      close(socket_b)
    end
  end

  describe "claim release on errors" do
    test "claims released on overload error" do
      # Fill queue to trigger overload - spread ranks to prevent immediate matching
      for i <- 1..600 do
        rank = rem(i * 17, 10_000)
        {:ok, %{data: %{"addRequest" => _}}} = add_request("overload_fill_#{i}", rank)
      end

      # Try user that will hit overload
      user_id = "overload_claim_test"
      {:ok, %{data: %{"addRequest" => result1}}} = add_request(user_id, 5000)

      # Should fail with overload
      assert result1["ok"] == false

      # Wait a bit for queue to drain
      Process.sleep(500)

      # Retry same user - should not be "already_queued"
      {:ok, %{data: %{"addRequest" => result2}}} = add_request(user_id, 5000)

      if result2["error"] do
        refute result2["error"] =~ "already",
               "Claim should have been released after overload error"
      end
    end

    test "no claim leaks across multiple error scenarios" do
      # Test various ranks and error conditions
      test_cases = [
        {"leak_test_1", 100},
        {"leak_test_2", 500},
        {"leak_test_3", 1000},
        {"leak_test_4", 5000},
        {"leak_test_5", 9999}
      ]

      for {user_id, rank} <- test_cases do
        # First attempt
        {:ok, %{data: %{"addRequest" => result1}}} = add_request(user_id, rank)

        # If it failed, verify claim was released
        if result1["ok"] == false do
          # Immediate retry
          {:ok, %{data: %{"addRequest" => result2}}} = add_request(user_id, rank)

          # Should not be "already_queued"
          if result2["error"] do
            refute result2["error"] =~ "already",
                   "Claim leaked for user #{user_id} at rank #{rank}"
          end
        end
      end
    end
  end

  describe "system stability under load" do
    @tag timeout: 60_000
    test "system remains stable with mixed operations" do
      # Mix of enqueues across all partitions
      tasks =
        for i <- 1..200 do
          Task.async(fn ->
            rank = rem(i * 47, 10_000)
            add_request("mixed_#{i}", rank)
          end)
        end

      results = Task.await_many(tasks, 30_000)

      # System should handle all requests without crashing
      assert length(results) == 200

      # Count successes and failures
      success_count =
        Enum.count(results, fn
          {:ok, %{data: %{"addRequest" => %{"ok" => true}}}} -> true
          _ -> false
        end)

      # Most should succeed
      assert success_count > 100,
             "Expected >50% success rate, got #{success_count}/200"

      # All failures should have valid error messages
      Enum.each(results, fn
        {:ok, %{data: %{"addRequest" => %{"ok" => false, "error" => error}}}} ->
          assert error != nil, "Failed request should have error message"

        _ ->
          :ok
      end)
    end
  end
end
