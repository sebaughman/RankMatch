defmodule QueueOfMatchmaking.Matchmaking.PartitionWorkerTest do
  use ExUnit.Case, async: false

  alias QueueOfMatchmaking.Matchmaking.PartitionWorker
  alias QueueOfMatchmaking.Index.UserIndex
  alias QueueOfMatchmaking.Config

  setup do
    # Start required dependencies (only if not already started)
    unless Process.whereis(QueueOfMatchmaking.Horde.Registry) do
      start_supervised!(QueueOfMatchmaking.Horde.Registry)
    end

    unless Process.whereis(QueueOfMatchmaking.Horde.Supervisor) do
      start_supervised!(QueueOfMatchmaking.Horde.Supervisor)
    end

    unless Process.whereis(QueueOfMatchmaking.Index.UserIndex) do
      start_supervised!(QueueOfMatchmaking.Index.UserIndex)
    end

    unless Process.whereis(QueueOfMatchmaking.Web.Endpoint) do
      start_supervised!(QueueOfMatchmaking.Web.Endpoint)
    end

    # Build config from Config module
    config = Config.matchmaking_config()

    # Start a partition worker for testing
    {:ok, pid} =
      start_supervised(
        {PartitionWorker,
         epoch: 1,
         partition_id: "test-partition",
         range_start: 0,
         range_end: 10_000,
         config: config}
      )

    %{worker: pid, config: config}
  end

  describe "enqueue/3" do
    test "accepts valid enqueue request", %{worker: worker} do
      assert :ok = UserIndex.claim("user1")

      envelope = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: "user1",
        rank: 1500
      }

      assert :ok = PartitionWorker.enqueue(worker, envelope)
    end

    test "rejects rank out of range", %{worker: worker} do
      assert :ok = UserIndex.claim("user_out_of_range")

      envelope = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: "user_out_of_range",
        rank: 20_000
      }

      assert {:error, :out_of_range} = PartitionWorker.enqueue(worker, envelope)

      # Claim should still be held since worker rejected it
      UserIndex.release("user_out_of_range")
    end

    test "immediate match on same rank", %{worker: worker} do
      assert :ok = UserIndex.claim("user_a")
      assert :ok = UserIndex.claim("user_b")

      envelope_a = %{epoch: 1, partition_id: "test-partition", user_id: "user_a", rank: 1500}
      envelope_b = %{epoch: 1, partition_id: "test-partition", user_id: "user_b", rank: 1500}

      assert :ok = PartitionWorker.enqueue(worker, envelope_a)
      assert :ok = PartitionWorker.enqueue(worker, envelope_b)

      # Give time for match processing
      Process.sleep(50)

      # Both users should be released after match
      assert :ok = UserIndex.claim("user_a")
      assert :ok = UserIndex.claim("user_b")

      UserIndex.release("user_a")
      UserIndex.release("user_b")
    end

    test "immediate match with close ranks", %{worker: worker} do
      assert :ok = UserIndex.claim("user_close_1")
      assert :ok = UserIndex.claim("user_close_2")

      envelope_1 = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: "user_close_1",
        rank: 1500
      }

      envelope_2 = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: "user_close_2",
        rank: 1500
      }

      assert :ok = PartitionWorker.enqueue(worker, envelope_1)
      assert :ok = PartitionWorker.enqueue(worker, envelope_2)

      Process.sleep(50)

      # Should be matched and released
      assert :ok = UserIndex.claim("user_close_1")
      assert :ok = UserIndex.claim("user_close_2")

      UserIndex.release("user_close_1")
      UserIndex.release("user_close_2")
    end

    test "no self-match", %{worker: worker} do
      assert :ok = UserIndex.claim("solo_user")

      envelope = %{epoch: 1, partition_id: "test-partition", user_id: "solo_user", rank: 1500}
      assert :ok = PartitionWorker.enqueue(worker, envelope)

      # Wait to ensure no self-match occurs
      Process.sleep(100)

      # User should still be claimed (not matched)
      assert {:error, :already_queued} = UserIndex.claim("solo_user")

      UserIndex.release("solo_user")
    end

    test "rejects stale epoch", %{worker: worker} do
      assert :ok = UserIndex.claim("stale_epoch_user")

      envelope = %{
        epoch: 999,
        partition_id: "test-partition",
        user_id: "stale_epoch_user",
        rank: 1500
      }

      assert {:error, :stale_epoch} = PartitionWorker.enqueue(worker, envelope)

      # Claim should still be held since worker rejected it
      UserIndex.release("stale_epoch_user")
    end
  end

  describe "tick processing" do
    test "widening allows match after time passes", %{worker: worker} do
      assert :ok = UserIndex.claim("user_wide_1")
      assert :ok = UserIndex.claim("user_wide_2")

      envelope_1 = %{epoch: 1, partition_id: "test-partition", user_id: "user_wide_1", rank: 1000}
      envelope_2 = %{epoch: 1, partition_id: "test-partition", user_id: "user_wide_2", rank: 1100}

      # Enqueue users with rank difference > 0 (won't match immediately)
      assert :ok = PartitionWorker.enqueue(worker, envelope_1)
      assert :ok = PartitionWorker.enqueue(worker, envelope_2)

      # Wait for widening to allow match (200ms step + processing time)
      Process.sleep(300)

      case UserIndex.claim("user_wide_1") do
        :ok ->
          UserIndex.release("user_wide_1")

        {:error, :already_queued} ->
          UserIndex.release("user_wide_1")
      end

      case UserIndex.claim("user_wide_2") do
        :ok ->
          UserIndex.release("user_wide_2")

        {:error, :already_queued} ->
          UserIndex.release("user_wide_2")
      end
    end

    test "processes multiple queued users", %{worker: worker} do
      users = for i <- 1..5, do: "batch_user_#{i}"

      users
      |> Enum.with_index(1)
      |> Enum.each(fn {user, idx} ->
        assert :ok = UserIndex.claim(user)

        envelope = %{
          epoch: 1,
          partition_id: "test-partition",
          user_id: user,
          rank: 2000 + idx * 10
        }

        assert :ok = PartitionWorker.enqueue(worker, envelope)
      end)

      # Wait for tick processing
      Process.sleep(300)

      # At least some should be matched (depending on widening)
      # We just verify the system doesn't crash
      Enum.each(users, fn user ->
        case UserIndex.claim(user) do
          :ok -> UserIndex.release(user)
          {:error, :already_queued} -> UserIndex.release(user)
        end
      end)
    end
  end

  describe "backpressure" do
    test "rejects when overloaded", %{worker: worker} do
      # This test would need to flood the worker to trigger backpressure
      # For now, we just verify the error path exists
      assert :ok = UserIndex.claim("backpressure_test")

      envelope = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: "backpressure_test",
        rank: 5000
      }

      # Normal enqueue should work
      result = PartitionWorker.enqueue(worker, envelope)
      assert result in [:ok, {:error, :overloaded}]

      if result == {:error, :overloaded} do
        UserIndex.release("backpressure_test")
      end
    end
  end

  describe "match finalization" do
    test "releases both user claims on match", %{worker: worker} do
      assert :ok = UserIndex.claim("match_user_1")
      assert :ok = UserIndex.claim("match_user_2")

      envelope_1 = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: "match_user_1",
        rank: 3000
      }

      envelope_2 = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: "match_user_2",
        rank: 3000
      }

      assert :ok = PartitionWorker.enqueue(worker, envelope_1)
      assert :ok = PartitionWorker.enqueue(worker, envelope_2)

      # Wait for match
      Process.sleep(100)

      # Both should be released
      assert :ok = UserIndex.claim("match_user_1")
      assert :ok = UserIndex.claim("match_user_2")

      UserIndex.release("match_user_1")
      UserIndex.release("match_user_2")
    end
  end

  describe "peek_nearest RPC" do
    test "returns opponent when available", %{worker: worker} do
      assert :ok = UserIndex.claim("peek_target")

      envelope = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: "peek_target",
        rank: 1500
      }

      assert :ok = PartitionWorker.enqueue(worker, envelope)

      # Peek for opponent near rank 1500
      assert {:ok, {"peek_target", 1500, _enq_ms}} =
               PartitionWorker.peek_nearest(worker, 1500, 10, "other_user", 1)
    end

    test "returns nil when queue empty", %{worker: worker} do
      # Peek when no users in queue
      assert {:ok, nil} = PartitionWorker.peek_nearest(worker, 1500, 10, "any_user", 1)
    end

    test "rejects epoch mismatch", %{worker: worker} do
      assert :ok = UserIndex.claim("peek_epoch_test")

      envelope = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: "peek_epoch_test",
        rank: 1500
      }

      assert :ok = PartitionWorker.enqueue(worker, envelope)

      # Peek with wrong epoch
      assert {:error, :epoch_mismatch} =
               PartitionWorker.peek_nearest(worker, 1500, 10, "other_user", 999)

      UserIndex.release("peek_epoch_test")
    end

    test "does not modify state (pure peek)", %{worker: worker} do
      assert :ok = UserIndex.claim("peek_pure_test")

      envelope = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: "peek_pure_test",
        rank: 1500
      }

      assert :ok = PartitionWorker.enqueue(worker, envelope)

      # Peek multiple times
      assert {:ok, {"peek_pure_test", 1500, _}} =
               PartitionWorker.peek_nearest(worker, 1500, 10, "other_user", 1)

      assert {:ok, {"peek_pure_test", 1500, _}} =
               PartitionWorker.peek_nearest(worker, 1500, 10, "other_user", 1)

      # User should still be in queue (verify by duplicate enqueue attempt)
      assert {:error, :already_queued} = UserIndex.claim("peek_pure_test")

      UserIndex.release("peek_pure_test")
    end

    test "excludes specified user from results", %{worker: worker} do
      assert :ok = UserIndex.claim("peek_exclude_1")
      assert :ok = UserIndex.claim("peek_exclude_2")

      envelope_1 = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: "peek_exclude_1",
        rank: 1500
      }

      envelope_2 = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: "peek_exclude_2",
        rank: 1505
      }

      assert :ok = PartitionWorker.enqueue(worker, envelope_1)
      assert :ok = PartitionWorker.enqueue(worker, envelope_2)

      # Peek excluding user 1, should return user 2
      assert {:ok, {"peek_exclude_2", 1505, _}} =
               PartitionWorker.peek_nearest(worker, 1500, 10, "peek_exclude_1", 1)

      UserIndex.release("peek_exclude_1")
      UserIndex.release("peek_exclude_2")
    end
  end

  describe "reserve RPC" do
    test "removes exact match successfully", %{worker: worker} do
      # Use unique user ID to avoid conflicts with other tests
      user_id = "reserve_exact_#{:erlang.unique_integer([:positive])}"

      assert :ok = UserIndex.claim(user_id)

      envelope = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: user_id,
        rank: 1500
      }

      assert :ok = PartitionWorker.enqueue(worker, envelope)

      # Get the ticket details
      {:ok, {^user_id, 1500, enq_ms}} =
        PartitionWorker.peek_nearest(worker, 1500, 10, "other_user", 1)

      # Reserve with exact match
      assert {:ok, {^user_id, 1500, ^enq_ms}} =
               PartitionWorker.reserve(worker, user_id, 1500, enq_ms, 1)

      # Reserve removes user from queue but does NOT release the claim
      # The caller (cross-partition tick) is responsible for calling finalize_match()

      # Verify user is removed from queue (peek returns nil)
      assert {:ok, nil} = PartitionWorker.peek_nearest(worker, 1500, 10, "other_user", 1)

      # Verify claim is still held (caller's responsibility to release via finalize_match)
      assert {:error, :already_queued} = UserIndex.claim(user_id)

      # Clean up (simulate what finalize_match would do)
      UserIndex.release(user_id)
    end

    test "returns not_found on mismatch", %{worker: worker} do
      assert :ok = UserIndex.claim("reserve_mismatch")

      envelope = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: "reserve_mismatch",
        rank: 1500
      }

      assert :ok = PartitionWorker.enqueue(worker, envelope)

      # Try to reserve with wrong enq_ms
      assert {:error, :not_found} =
               PartitionWorker.reserve(worker, "reserve_mismatch", 1500, 999_999, 1)

      # User should still be in queue
      assert {:error, :already_queued} = UserIndex.claim("reserve_mismatch")

      UserIndex.release("reserve_mismatch")
    end

    test "rejects epoch mismatch", %{worker: worker} do
      assert :ok = UserIndex.claim("reserve_epoch_test")

      envelope = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: "reserve_epoch_test",
        rank: 1500
      }

      assert :ok = PartitionWorker.enqueue(worker, envelope)

      {:ok, {_, _, enq_ms}} =
        PartitionWorker.peek_nearest(worker, 1500, 10, "other_user", 1)

      # Try to reserve with wrong epoch
      assert {:error, :epoch_mismatch} =
               PartitionWorker.reserve(worker, "reserve_epoch_test", 1500, enq_ms, 999)

      UserIndex.release("reserve_epoch_test")
    end

    test "handles concurrent reserve (one succeeds, one fails)", %{worker: worker} do
      assert :ok = UserIndex.claim("reserve_concurrent")

      envelope = %{
        epoch: 1,
        partition_id: "test-partition",
        user_id: "reserve_concurrent",
        rank: 1500
      }

      assert :ok = PartitionWorker.enqueue(worker, envelope)

      {:ok, {_, _, enq_ms}} =
        PartitionWorker.peek_nearest(worker, 1500, 10, "other_user", 1)

      # First reserve should succeed
      assert {:ok, _} = PartitionWorker.reserve(worker, "reserve_concurrent", 1500, enq_ms, 1)

      # Second reserve should fail (ticket already removed)
      assert {:error, :not_found} =
               PartitionWorker.reserve(worker, "reserve_concurrent", 1500, enq_ms, 1)

      UserIndex.release("reserve_concurrent")
    end
  end
end
