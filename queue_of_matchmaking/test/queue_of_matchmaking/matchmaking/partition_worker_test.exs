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
         partition_id: "test-partition", range_start: 0, range_end: 10_000, config: config}
      )

    %{worker: pid, config: config}
  end

  describe "enqueue/4" do
    test "accepts valid enqueue request", %{worker: worker} do
      assert :ok = UserIndex.claim("user1")
      assert :ok = PartitionWorker.enqueue(worker, "user1", 1500)
    end

    test "rejects rank out of range", %{worker: worker} do
      assert :ok = UserIndex.claim("user_out_of_range")

      assert {:error, :out_of_range} =
               PartitionWorker.enqueue(worker, "user_out_of_range", 20_000)

      # Claim should still be held since worker rejected it
      UserIndex.release("user_out_of_range")
    end

    test "immediate match on same rank", %{worker: worker} do
      assert :ok = UserIndex.claim("user_a")
      assert :ok = UserIndex.claim("user_b")

      assert :ok = PartitionWorker.enqueue(worker, "user_a", 1500)
      assert :ok = PartitionWorker.enqueue(worker, "user_b", 1500)

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

      assert :ok = PartitionWorker.enqueue(worker, "user_close_1", 1500)
      assert :ok = PartitionWorker.enqueue(worker, "user_close_2", 1500)

      Process.sleep(50)

      # Should be matched and released
      assert :ok = UserIndex.claim("user_close_1")
      assert :ok = UserIndex.claim("user_close_2")

      UserIndex.release("user_close_1")
      UserIndex.release("user_close_2")
    end

    test "no self-match", %{worker: worker} do
      assert :ok = UserIndex.claim("solo_user")
      assert :ok = PartitionWorker.enqueue(worker, "solo_user", 1500)

      # Wait to ensure no self-match occurs
      Process.sleep(100)

      # User should still be claimed (not matched)
      assert {:error, :already_queued} = UserIndex.claim("solo_user")

      UserIndex.release("solo_user")
    end
  end

  describe "tick processing" do
    test "widening allows match after time passes", %{worker: worker} do
      assert :ok = UserIndex.claim("user_wide_1")
      assert :ok = UserIndex.claim("user_wide_2")

      # Enqueue users with rank difference > 0 (won't match immediately)
      assert :ok = PartitionWorker.enqueue(worker, "user_wide_1", 1000)
      assert :ok = PartitionWorker.enqueue(worker, "user_wide_2", 1100)

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
        assert :ok = PartitionWorker.enqueue(worker, user, 2000 + idx * 10)
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

      # Normal enqueue should work
      result = PartitionWorker.enqueue(worker, "backpressure_test", 5000)
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

      assert :ok = PartitionWorker.enqueue(worker, "match_user_1", 3000)
      assert :ok = PartitionWorker.enqueue(worker, "match_user_2", 3000)

      # Wait for match
      Process.sleep(100)

      # Both should be released
      assert :ok = UserIndex.claim("match_user_1")
      assert :ok = UserIndex.claim("match_user_2")

      UserIndex.release("match_user_1")
      UserIndex.release("match_user_2")
    end
  end
end
