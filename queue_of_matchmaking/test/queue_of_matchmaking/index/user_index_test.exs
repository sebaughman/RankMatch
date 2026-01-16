defmodule QueueOfMatchmaking.Index.UserIndexTest do
  use ExUnit.Case, async: false

  alias QueueOfMatchmaking.Index.UserIndex

  setup do
    # Give shards time to start
    Process.sleep(100)
    :ok
  end

  describe "claim/1" do
    test "returns :ok for first claim" do
      user_id = "user_#{:rand.uniform(1_000_000)}"
      assert :ok = UserIndex.claim(user_id)
    end

    test "returns error for duplicate claim" do
      user_id = "user_#{:rand.uniform(1_000_000)}"
      assert :ok = UserIndex.claim(user_id)
      assert {:error, :already_queued} = UserIndex.claim(user_id)
    end

    test "allows claim after release" do
      user_id = "user_#{:rand.uniform(1_000_000)}"
      assert :ok = UserIndex.claim(user_id)
      UserIndex.release(user_id)
      Process.sleep(10)
      assert :ok = UserIndex.claim(user_id)
    end

    test "multiple users can claim different IDs" do
      user1 = "user_#{:rand.uniform(1_000_000)}"
      user2 = "user_#{:rand.uniform(1_000_000)}"
      user3 = "user_#{:rand.uniform(1_000_000)}"

      assert :ok = UserIndex.claim(user1)
      assert :ok = UserIndex.claim(user2)
      assert :ok = UserIndex.claim(user3)
    end

    test "sharding distributes users correctly" do
      # Test that same user always routes to same shard
      user_id = "consistent_user_#{:rand.uniform(1_000_000)}"

      assert :ok = UserIndex.claim(user_id)
      assert {:error, :already_queued} = UserIndex.claim(user_id)

      UserIndex.release(user_id)
      Process.sleep(10)

      assert :ok = UserIndex.claim(user_id)
    end
  end

  describe "release/1" do
    test "release is idempotent" do
      user_id = "user_#{:rand.uniform(1_000_000)}"
      assert :ok = UserIndex.claim(user_id)

      UserIndex.release(user_id)
      UserIndex.release(user_id)
      UserIndex.release(user_id)

      Process.sleep(10)
      assert :ok = UserIndex.claim(user_id)
    end
  end
end
