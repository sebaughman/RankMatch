defmodule QueueOfMatchmaking.Graphql.DuplicateTest do
  use ExUnit.Case, async: false

  alias QueueOfMatchmaking.Graphql.Resolvers

  setup_all do
    # Restart application to ensure clean state between test modules
    :ok = Application.stop(:queue_of_matchmaking)
    {:ok, _} = Application.ensure_all_started(:queue_of_matchmaking)
    Process.sleep(100)
    :ok
  end

  setup do
    # Give shards time to start
    Process.sleep(100)
    :ok
  end

  describe "add_request/2 duplicate prevention" do
    test "accepts first request" do
      user_id = "player_#{:rand.uniform(1_000_000)}"
      args = %{user_id: user_id, rank: 1500}

      assert {:ok, %{ok: true, error: nil}} = Resolvers.add_request(args, nil)
    end

    test "rejects duplicate request for same user" do
      user_id = "player_#{:rand.uniform(1_000_000)}"
      # Use different ranks to prevent immediate matching
      args = %{user_id: user_id, rank: 5000}

      assert {:ok, %{ok: true, error: nil}} = Resolvers.add_request(args, nil)
      # Small delay to ensure first request is processed
      Process.sleep(10)
      assert {:ok, %{ok: false, error: "already_queued"}} = Resolvers.add_request(args, nil)
    end

    test "different users can enqueue with same rank" do
      user1 = "player_#{:rand.uniform(1_000_000)}"
      user2 = "player_#{:rand.uniform(1_000_000)}"

      args1 = %{user_id: user1, rank: 1500}
      args2 = %{user_id: user2, rank: 1500}

      assert {:ok, %{ok: true, error: nil}} = Resolvers.add_request(args1, nil)
      assert {:ok, %{ok: true, error: nil}} = Resolvers.add_request(args2, nil)
    end

    test "validation errors do not claim user" do
      user_id = "player_#{:rand.uniform(1_000_000)}"

      # First request with invalid rank
      args_invalid = %{user_id: user_id, rank: -1}
      assert {:ok, %{ok: false, error: error}} = Resolvers.add_request(args_invalid, nil)
      assert error == "rank must be a non-negative integer"

      # Second request with valid rank should succeed (no claim was made)
      args_valid = %{user_id: user_id, rank: 1500}
      assert {:ok, %{ok: true, error: nil}} = Resolvers.add_request(args_valid, nil)
    end
  end
end
