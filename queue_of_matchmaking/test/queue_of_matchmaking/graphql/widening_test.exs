defmodule QueueOfMatchmaking.Graphql.WideningTest do
  @moduledoc """
  Tests for time-based rank widening via GraphQL interface.
  Verifies that allowed rank difference expands over time.
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

  describe "time-based widening" do
    test "users with diff 100 do not match immediately but match after widening" do
      user_a = unique_user_id("widen_a")
      user_b = unique_user_id("widen_b")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, sub_id_b} = subscribe_to_match(user_b)

      assert_request_ok(add_request(user_a, 1000))

      refute_match_received(40)

      # Wait for widening: diff=100 requires 50ms (100/50*25=50ms)
      Process.sleep(60)

      assert_request_ok(add_request(user_b, 1100))

      users_a = assert_match_received(sub_id_a, 500)
      users_b = assert_match_received(sub_id_b, 500)

      matched_ids = extract_user_ids(users_a)
      assert matched_ids == Enum.sort([user_a, user_b])
      assert users_a == users_b
    end

    test "widening expands gradually over multiple steps" do
      user_a = unique_user_id("gradual_a")
      user_b = unique_user_id("gradual_b")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, sub_id_b} = subscribe_to_match(user_b)

      assert_request_ok(add_request(user_a, 2000))

      # Wait for widening: diff=200 requires 100ms (200/25*50=400 > 200)
      Process.sleep(110)

      assert_request_ok(add_request(user_b, 2200))

      users_a = assert_match_received(sub_id_a, 200)
      _users_b = assert_match_received(sub_id_b, 200)

      matched_ids = extract_user_ids(users_a)
      assert matched_ids == Enum.sort([user_a, user_b])
    end

    test "widening allows match after sufficient time has passed" do
      user_a = unique_user_id("time_a")
      user_b = unique_user_id("time_b")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, sub_id_b} = subscribe_to_match(user_b)

      assert_request_ok(add_request(user_a, 3000))

      refute_match_received(40)

      Process.sleep(80)

      assert_request_ok(add_request(user_b, 3150))

      users_a = assert_match_received(sub_id_a, 500)
      _users_b = assert_match_received(sub_id_b, 500)

      matched_ids = extract_user_ids(users_a)
      assert matched_ids == Enum.sort([user_a, user_b])
    end

    test "widening respects cap at 1000" do
      user_a = unique_user_id("cap_a")
      user_b = unique_user_id("cap_b")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, sub_id_b} = subscribe_to_match(user_b)

      assert_request_ok(add_request(user_a, 4000))

      # Wait for widening: diff=999 requires 500ms to reach cap (999/25*50=1996, capped at 1000)
      Process.sleep(500)

      assert_request_ok(add_request(user_b, 4999))

      users_a = assert_match_received(sub_id_a, 300)
      _users_b = assert_match_received(sub_id_b, 300)

      matched_ids = extract_user_ids(users_a)
      assert matched_ids == Enum.sort([user_a, user_b])
    end

    test "widening does not match beyond cap" do
      user_a = unique_user_id("beyond_cap_a")
      user_b = unique_user_id("beyond_cap_b")

      {_socket_a, _sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, _sub_id_b} = subscribe_to_match(user_b)

      assert_request_ok(add_request(user_a, 5000))

      Process.sleep(100)

      assert_request_ok(add_request(user_b, 6100))

      refute_match_received(150)
    end

    test "multiple users widen and match correctly" do
      user_a = unique_user_id("multi_a")
      user_b = unique_user_id("multi_b")
      user_c = unique_user_id("multi_c")

      {_socket_a, sub_id_a} = subscribe_to_match(user_a)
      {_socket_b, _sub_id_b} = subscribe_to_match(user_b)
      {_socket_c, sub_id_c} = subscribe_to_match(user_c)

      assert_request_ok(add_request(user_a, 6000))
      # Wait for widening: diff=20 (a-c) requires minimal time, diff=80 (a-b) requires 40ms
      Process.sleep(20)
      assert_request_ok(add_request(user_b, 6080))
      Process.sleep(20)
      assert_request_ok(add_request(user_c, 6020))

      users_a = assert_match_received(sub_id_a, 200)
      _users_c = assert_match_received(sub_id_c, 200)

      matched_ids = extract_user_ids(users_a)
      assert matched_ids == Enum.sort([user_a, user_c])

      refute_match_received(50)
    end

    test "widening works across different rank ranges" do
      pairs = [
        {unique_user_id("low_a"), unique_user_id("low_b"), 100, 180},
        {unique_user_id("mid_a"), unique_user_id("mid_b"), 5000, 5090},
        {unique_user_id("high_a"), unique_user_id("high_b"), 9900, 9980}
      ]

      subscriptions =
        Enum.flat_map(pairs, fn {user_a, user_b, _rank_a, _rank_b} ->
          [{user_a, subscribe_to_match(user_a)}, {user_b, subscribe_to_match(user_b)}]
        end)

      Enum.each(pairs, fn {user_a, user_b, rank_a, rank_b} ->
        assert_request_ok(add_request(user_a, rank_a))
        # Wait for widening: max diff=90 requires 45ms (90/25*50=180 > 90)
        Process.sleep(50)
        assert_request_ok(add_request(user_b, rank_b))
      end)

      Enum.each(subscriptions, fn {_user_id, {_socket, sub_id}} ->
        assert_match_received(sub_id, 200)
      end)
    end
  end
end
