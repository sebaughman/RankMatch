defmodule QueueOfMatchmaking.Graphql.SubscriptionFilteringTest do
  @moduledoc """
  Tests for GraphQL subscription filtering and topic isolation.
  Verifies that users only receive notifications for their own matches.
  """

  use ExUnit.Case, async: false
  import QueueOfMatchmaking.GraphqlCase

  @endpoint QueueOfMatchmaking.Web.Endpoint

  setup_all do
    # Restart application to ensure clean state between test modules
    :ok = Application.stop(:queue_of_matchmaking)
    {:ok, _} = Application.ensure_all_started(:queue_of_matchmaking)
    wait_for_endpoint()
    :ok
  end

  setup do
    # Restart application before each test to prevent state leakage within module
    :ok = Application.stop(:queue_of_matchmaking)
    {:ok, _} = Application.ensure_all_started(:queue_of_matchmaking)
    wait_for_endpoint()
    :ok
  end

  describe "subscription filtering" do
    test "matched users receive notification on their subscriptions" do
      user_a = unique_user_id("filter_a")
      user_b = unique_user_id("filter_b")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, sub_id_b} = subscribe_to_match(user_b)

      assert_request_ok(add_request(user_a, 1500))
      assert_request_ok(add_request(user_b, 1500))

      users_a = assert_match_received(sub_id_a)
      users_b = assert_match_received(sub_id_b)

      assert extract_user_ids(users_a) == Enum.sort([user_a, user_b])
      assert extract_user_ids(users_b) == Enum.sort([user_a, user_b])
    end

    test "unrelated user does not receive match notification" do
      user_a = unique_user_id("unrelated_a")
      user_b = unique_user_id("unrelated_b")
      user_x = unique_user_id("unrelated_x")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, sub_id_b} = subscribe_to_match(user_b)
      {_socket_x, _sub_id_x} = subscribe_to_match(user_x)

      assert_request_ok(add_request(user_a, 2000))
      assert_request_ok(add_request(user_b, 2000))

      users_a = assert_match_received(sub_id_a)
      users_b = assert_match_received(sub_id_b)

      assert extract_user_ids(users_a) == Enum.sort([user_a, user_b])
      assert extract_user_ids(users_b) == Enum.sort([user_a, user_b])

      refute_match_received(100)
    end

    test "subscription topic isolation - multiple concurrent matches" do
      pair1_a = unique_user_id("pair1_a")
      pair1_b = unique_user_id("pair1_b")
      pair2_a = unique_user_id("pair2_a")
      pair2_b = unique_user_id("pair2_b")

      {_socket_1a, sub_id_1a} = subscribe_to_match(pair1_a)
      {_socket_1b, sub_id_1b} = subscribe_to_match(pair1_b)
      {_socket_2a, sub_id_2a} = subscribe_to_match(pair2_a)
      {_socket_2b, sub_id_2b} = subscribe_to_match(pair2_b)

      assert_request_ok(add_request(pair1_a, 3000))
      assert_request_ok(add_request(pair1_b, 3000))
      assert_request_ok(add_request(pair2_a, 4000))
      assert_request_ok(add_request(pair2_b, 4000))

      users_1a = assert_match_received(sub_id_1a)
      users_1b = assert_match_received(sub_id_1b)
      users_2a = assert_match_received(sub_id_2a)
      users_2b = assert_match_received(sub_id_2b)

      assert extract_user_ids(users_1a) == Enum.sort([pair1_a, pair1_b])
      assert extract_user_ids(users_1b) == Enum.sort([pair1_a, pair1_b])
      assert extract_user_ids(users_2a) == Enum.sort([pair2_a, pair2_b])
      assert extract_user_ids(users_2b) == Enum.sort([pair2_a, pair2_b])
    end

    test "subscription payload validation - correct structure" do
      user_a = unique_user_id("payload_a")
      user_b = unique_user_id("payload_b")
      rank = 5500

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, _sub_id_b} = subscribe_to_match(user_b)

      assert_request_ok(add_request(user_a, rank))
      assert_request_ok(add_request(user_b, rank))

      users = assert_match_received(sub_id_a)

      assert is_list(users)
      assert length(users) == 2

      Enum.each(users, fn user ->
        assert Map.has_key?(user, "userId")
        assert Map.has_key?(user, "userRank")
        assert is_binary(user["userId"])
        assert is_integer(user["userRank"])
        assert user["userRank"] == rank
      end)
    end

    test "subscription receives both users in match payload" do
      user_a = unique_user_id("both_a")
      user_b = unique_user_id("both_b")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, _sub_id_b} = subscribe_to_match(user_b)

      assert_request_ok(add_request(user_a, 6000))
      assert_request_ok(add_request(user_b, 6000))

      users = assert_match_received(sub_id_a)

      user_ids = extract_user_ids(users)
      assert user_a in user_ids
      assert user_b in user_ids
    end

    test "no cross-contamination between user subscriptions" do
      user_a = unique_user_id("cross_a")
      user_b = unique_user_id("cross_b")
      user_c = unique_user_id("cross_c")
      user_d = unique_user_id("cross_d")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, sub_id_b} = subscribe_to_match(user_b)
      {_socket_c, sub_id_c} = subscribe_to_match(user_c)
      {_socket_d, sub_id_d} = subscribe_to_match(user_d)

      assert_request_ok(add_request(user_a, 7000))
      assert_request_ok(add_request(user_b, 7000))

      users_a = assert_match_received(sub_id_a)
      users_b = assert_match_received(sub_id_b)

      assert extract_user_ids(users_a) == Enum.sort([user_a, user_b])
      assert extract_user_ids(users_b) == Enum.sort([user_a, user_b])

      refute_match_received(50)

      assert_request_ok(add_request(user_c, 8000))
      assert_request_ok(add_request(user_d, 8000))

      users_c = assert_match_received(sub_id_c)
      users_d = assert_match_received(sub_id_d)

      assert extract_user_ids(users_c) == Enum.sort([user_c, user_d])
      assert extract_user_ids(users_d) == Enum.sort([user_c, user_d])

      refute_match_received(50)
    end

    test "subscription filtering with widening matches" do
      user_a = unique_user_id("widen_filter_a")
      user_b = unique_user_id("widen_filter_b")
      user_x = unique_user_id("widen_filter_x")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, sub_id_b} = subscribe_to_match(user_b)
      {_socket_x, _sub_id_x} = subscribe_to_match(user_x)

      assert_request_ok(add_request(user_a, 9000))
      assert_request_ok(add_request(user_b, 9100))

      users_a = assert_match_received(sub_id_a, 200)
      users_b = assert_match_received(sub_id_b, 200)

      assert extract_user_ids(users_a) == Enum.sort([user_a, user_b])
      assert extract_user_ids(users_b) == Enum.sort([user_a, user_b])

      refute_match_received(100)
    end
  end
end
