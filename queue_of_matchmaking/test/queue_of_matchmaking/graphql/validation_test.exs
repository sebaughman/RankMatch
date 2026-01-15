defmodule QueueOfMatchmaking.Graphql.ValidationTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.Graphql.Resolvers

  describe "add_request/2 validation" do
    test "accepts valid userId and rank" do
      args = %{user_id: "Player123", rank: 1500}
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
      args = %{user_id: "Player123", rank: -1}
      assert {:ok, %{ok: false, error: error}} = Resolvers.add_request(args, nil)
      assert error == "rank must be a non-negative integer"
    end

    test "accepts rank 0" do
      args = %{user_id: "Player123", rank: 0}
      assert {:ok, %{ok: true, error: nil}} = Resolvers.add_request(args, nil)
    end

    test "accepts high rank" do
      args = %{user_id: "Player123", rank: 10_000}
      assert {:ok, %{ok: true, error: nil}} = Resolvers.add_request(args, nil)
    end
  end
end
