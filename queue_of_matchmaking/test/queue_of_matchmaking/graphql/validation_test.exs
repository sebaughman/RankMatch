defmodule QueueOfMatchmaking.Graphql.ValidationTest do
  use ExUnit.Case, async: false

  alias QueueOfMatchmaking.Graphql.Resolvers

  setup_all do
    # Restart application to ensure clean state between test modules
    :ok = Application.stop(:queue_of_matchmaking)
    {:ok, _} = Application.ensure_all_started(:queue_of_matchmaking)
    Process.sleep(100)
    :ok
  end

  describe "add_request/2 validation" do
    test "accepts valid userId and rank" do
      user_id = "Player_#{:rand.uniform(1_000_000)}"
      args = %{user_id: user_id, rank: 1500}
      assert {:ok, %{ok: true, error: nil}} = Resolvers.add_request(args, nil)
    end

    test "rejects empty userId" do
      args = %{user_id: "", rank: 1500}
      assert {:ok, %{ok: false, error: error}} = Resolvers.add_request(args, nil)
      assert error == "userId must be a non-empty string"
    end

    test "rejects nil userId" do
      args = %{user_id: nil, rank: 1500}
      assert {:ok, %{ok: false, error: error}} = Resolvers.add_request(args, nil)
      assert error == "userId must be a non-empty string"
    end

    test "rejects negative rank" do
      user_id = "Player_#{:rand.uniform(1_000_000)}"
      args = %{user_id: user_id, rank: -1}
      assert {:ok, %{ok: false, error: error}} = Resolvers.add_request(args, nil)
      assert error == "rank must be a non-negative integer"
    end

    test "accepts rank 0" do
      user_id = "Player_#{:rand.uniform(1_000_000)}"
      args = %{user_id: user_id, rank: 0}
      assert {:ok, %{ok: true, error: nil}} = Resolvers.add_request(args, nil)
    end

    test "accepts high rank" do
      user_id = "Player_#{:rand.uniform(1_000_000)}"
      args = %{user_id: user_id, rank: 10_000}
      assert {:ok, %{ok: true, error: nil}} = Resolvers.add_request(args, nil)
    end
  end
end
