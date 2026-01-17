defmodule QueueOfMatchmaking.Graphql.SameRankTest do
  @moduledoc """
  Tests for same-rank matching via GraphQL interface.
  Verifies immediate matching when users have identical ranks.
  """

  use ExUnit.Case, async: false
  import QueueOfMatchmaking.GraphqlCase

  @endpoint QueueOfMatchmaking.Web.Endpoint

  setup_all do
    # Restart application to ensure clean state between test modules
    :ok = Application.stop(:queue_of_matchmaking)
    {:ok, _} = Application.ensure_all_started(:queue_of_matchmaking)
    Process.sleep(100)
    :ok
  end

  setup do
    # Restart application before each test to prevent state leakage within module
    :ok = Application.stop(:queue_of_matchmaking)
    {:ok, _} = Application.ensure_all_started(:queue_of_matchmaking)
    Process.sleep(100)
    :ok
  end

  describe "same rank matching" do
    test "two users at same rank match immediately" do
      user_a = unique_user_id("same_a")
      user_b = unique_user_id("same_b")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, sub_id_b} = subscribe_to_match(user_b)

      result_a = add_request(user_a, 1500)
      assert_request_ok(result_a)

      result_b = add_request(user_b, 1500)
      assert_request_ok(result_b)

      users_a = assert_match_received(sub_id_a)
      users_b = assert_match_received(sub_id_b)

      matched_ids = extract_user_ids(users_a)
      assert matched_ids == Enum.sort([user_a, user_b])

      assert users_a == users_b
    end

    test "three users at same rank - first two match, third waits" do
      user_a = unique_user_id("three_a")
      user_b = unique_user_id("three_b")
      user_c = unique_user_id("three_c")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, sub_id_b} = subscribe_to_match(user_b)
      {_socket_c, _sub_id_c} = subscribe_to_match(user_c)

      assert_request_ok(add_request(user_a, 2000))
      assert_request_ok(add_request(user_b, 2000))
      assert_request_ok(add_request(user_c, 2000))

      users_a = assert_match_received(sub_id_a)
      _users_b = assert_match_received(sub_id_b)

      matched_ids = extract_user_ids(users_a)
      assert user_a in matched_ids
      assert user_b in matched_ids

      refute_match_received(50)
    end

    test "match payload contains correct userIds and ranks" do
      user_a = unique_user_id("payload_a")
      user_b = unique_user_id("payload_b")
      rank = 3500

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, _sub_id_b} = subscribe_to_match(user_b)

      assert_request_ok(add_request(user_a, rank))
      assert_request_ok(add_request(user_b, rank))

      users = assert_match_received(sub_id_a)

      assert length(users) == 2

      Enum.each(users, fn user ->
        assert is_binary(user["userId"])
        assert user["userId"] in [user_a, user_b]
        assert user["userRank"] == rank
      end)
    end

    test "both users receive match via subscription" do
      user_a = unique_user_id("both_a")
      user_b = unique_user_id("both_b")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, sub_id_b} = subscribe_to_match(user_b)

      assert_request_ok(add_request(user_a, 4200))
      assert_request_ok(add_request(user_b, 4200))

      users_a = assert_match_received(sub_id_a)
      users_b = assert_match_received(sub_id_b)

      assert extract_user_ids(users_a) == extract_user_ids(users_b)
      assert Enum.sort([user_a, user_b]) == extract_user_ids(users_a)
    end

    test "multiple concurrent same-rank matches" do
      pairs = [
        {unique_user_id("pair1_a"), unique_user_id("pair1_b"), 1000},
        {unique_user_id("pair2_a"), unique_user_id("pair2_b"), 2000},
        {unique_user_id("pair3_a"), unique_user_id("pair3_b"), 3000}
      ]

      subscriptions =
        Enum.flat_map(pairs, fn {user_a, user_b, _rank} ->
          [{user_a, subscribe_to_match(user_a)}, {user_b, subscribe_to_match(user_b)}]
        end)

      Enum.each(pairs, fn {user_a, user_b, rank} ->
        assert_request_ok(add_request(user_a, rank))
        assert_request_ok(add_request(user_b, rank))
      end)

      Enum.each(subscriptions, fn {user_id, {_socket, sub_id}} ->
        users = assert_match_received(sub_id)
        matched_ids = extract_user_ids(users)
        assert user_id in matched_ids
      end)
    end
  end
end
