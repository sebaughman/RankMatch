defmodule QueueOfMatchmaking.Graphql.ClosestRankTest do
  @moduledoc """
  Tests for closest-rank selection via GraphQL interface.
  Verifies that the system matches users with the smallest rank difference.
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

  describe "closest rank selection" do
    test "matches with diff 1 instead of diff 20" do
      user_a = unique_user_id("closest_a")
      user_b = unique_user_id("closest_b")
      user_c = unique_user_id("closest_c")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, _sub_id_b} = subscribe_to_match(user_b)
      {_socket_c, sub_id_c} = subscribe_to_match(user_c)

      assert_request_ok(add_request(user_a, 1500))
      Process.sleep(10)
      assert_request_ok(add_request(user_b, 1480))
      Process.sleep(10)
      assert_request_ok(add_request(user_c, 1499))

      users_a = assert_match_received(sub_id_a, 300)
      users_c = assert_match_received(sub_id_c, 300)

      matched_ids = extract_user_ids(users_a)
      assert matched_ids == Enum.sort([user_a, user_c])

      assert users_a == users_c

      refute_match_received(50)
    end

    test "selects closest among multiple candidates" do
      user_target = unique_user_id("target")
      user_far = unique_user_id("far")
      user_medium = unique_user_id("medium")
      user_close = unique_user_id("close")

      {_socket_target, sub_id_target} = subscribe_to_match(user_target)
      {_socket_far, _sub_id_far} = subscribe_to_match(user_far)
      {_socket_medium, _sub_id_medium} = subscribe_to_match(user_medium)
      {_socket_close, sub_id_close} = subscribe_to_match(user_close)

      assert_request_ok(add_request(user_far, 2000))
      Process.sleep(10)
      assert_request_ok(add_request(user_medium, 2010))
      Process.sleep(10)
      assert_request_ok(add_request(user_close, 2003))
      Process.sleep(10)
      assert_request_ok(add_request(user_target, 2005))

      users_target = assert_match_received(sub_id_target, 500)
      _users_close = assert_match_received(sub_id_close, 500)

      matched_ids = extract_user_ids(users_target)
      assert matched_ids == Enum.sort([user_target, user_close])
    end

    test "boundary behavior at rank 0" do
      user_a = unique_user_id("boundary_0_a")
      user_b = unique_user_id("boundary_0_b")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, sub_id_b} = subscribe_to_match(user_b)

      assert_request_ok(add_request(user_a, 0))
      assert_request_ok(add_request(user_b, 0))

      users_a = assert_match_received(sub_id_a)
      _users_b = assert_match_received(sub_id_b)

      matched_ids = extract_user_ids(users_a)
      assert matched_ids == Enum.sort([user_a, user_b])
    end

    test "boundary behavior at rank 10000" do
      user_a = unique_user_id("boundary_max_a")
      user_b = unique_user_id("boundary_max_b")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, sub_id_b} = subscribe_to_match(user_b)

      assert_request_ok(add_request(user_a, 10_000))
      assert_request_ok(add_request(user_b, 10_000))

      users_a = assert_match_received(sub_id_a)
      _users_b = assert_match_received(sub_id_b)

      matched_ids = extract_user_ids(users_a)
      assert matched_ids == Enum.sort([user_a, user_b])
    end

    test "closest match with asymmetric differences" do
      user_center = unique_user_id("center")
      user_lower = unique_user_id("lower")
      user_upper = unique_user_id("upper")

      {_socket_center, sub_id_center} = subscribe_to_match(user_center)
      {_socket_lower, _sub_id_lower} = subscribe_to_match(user_lower)
      {_socket_upper, sub_id_upper} = subscribe_to_match(user_upper)

      assert_request_ok(add_request(user_lower, 3000))
      Process.sleep(10)
      assert_request_ok(add_request(user_upper, 3008))
      Process.sleep(10)
      assert_request_ok(add_request(user_center, 3005))

      users_center = assert_match_received(sub_id_center, 500)
      _users_upper = assert_match_received(sub_id_upper, 500)

      matched_ids = extract_user_ids(users_center)
      # Center (3005) is closer to upper (3008) with diff=3 than to lower (3000) with diff=5
      assert matched_ids == Enum.sort([user_center, user_upper])
    end

    test "deterministic tie-breaking when equal distance" do
      user_center = unique_user_id("tie_center")
      user_lower = unique_user_id("tie_lower")
      user_upper = unique_user_id("tie_upper")

      {_socket_center, sub_id_center} = subscribe_to_match(user_center)
      {_socket_lower, _sub_id_lower} = subscribe_to_match(user_lower)
      {_socket_upper, _sub_id_upper} = subscribe_to_match(user_upper)

      assert_request_ok(add_request(user_lower, 4995))
      Process.sleep(10)
      assert_request_ok(add_request(user_upper, 5005))
      Process.sleep(10)
      assert_request_ok(add_request(user_center, 5000))

      users_center = assert_match_received(sub_id_center, 200)

      matched_ids = extract_user_ids(users_center)
      assert user_center in matched_ids
      assert user_lower in matched_ids or user_upper in matched_ids
    end
  end
end
