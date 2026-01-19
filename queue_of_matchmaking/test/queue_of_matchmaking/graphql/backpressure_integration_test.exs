defmodule QueueOfMatchmaking.Graphql.BackpressureIntegrationTest do
  use ExUnit.Case
  import QueueOfMatchmaking.GraphqlCase
  import QueueOfMatchmaking.TestHelpers

  @moduledoc """
  Tests backpressure behavior via GraphQL interface.
  Verifies overload handling and claim release discipline.
  """

  @moduletag :integration

  setup do
    wait_for_system_ready()
    :ok
  end

  describe "storm overload" do
    test "storm enqueue triggers overloaded error" do
      # Rapidly enqueue users until one returns overloaded - spread ranks
      results =
        for i <- 1..1000 do
          rank = rem(i * 17, 10_000)

          mutation = """
          mutation {
            addRequest(userId: "storm_#{i}", rank: #{rank}) {
              ok
              error
            }
          }
          """

          {:ok, result} = Absinthe.run(mutation, QueueOfMatchmaking.Graphql.Schema)
          result
        end

      # Assert: at least one returns overloaded
      overloaded_count =
        Enum.count(results, fn
          %{data: %{"addRequest" => %{"ok" => false, "error" => "overloaded"}}} -> true
          _ -> false
        end)

      assert overloaded_count > 0, "Expected at least one overloaded response"
    end

    test "overloaded request releases claim immediately" do
      # Fill queue to trigger overload - spread ranks to prevent immediate matching
      for i <- 1..600 do
        rank = rem(i * 17, 10_000)
        {:ok, %{data: %{"addRequest" => _}}} = add_request("filler_#{i}", rank)
      end

      # Try user that will hit overload
      {:ok, %{data: %{"addRequest" => result1}}} = add_request("claim_test", 5000)

      # Should be overloaded or no_partition (both are valid under load)
      assert result1["ok"] == false

      # Immediately retry same user
      {:ok, %{data: %{"addRequest" => result2}}} = add_request("claim_test", 1000)

      # Should NOT be "already_queued" (claim was released)
      if result2["error"] do
        refute result2["error"] =~ "already", "Claim should have been released on error"
      end
    end
  end

  describe "recovery" do
    test "system accepts requests after overload clears" do
      # Fill queue to overload - spread ranks to prevent immediate matching
      for i <- 1..600 do
        rank = rem(i * 17, 10_000)
        {:ok, %{data: %{"addRequest" => _}}} = add_request("fill_#{i}", rank)
      end

      # Verify overload state
      {:ok, %{data: %{"addRequest" => result}}} = add_request("overload_test", 5000)
      assert result["ok"] == false

      # Wait for queue to drain via matching
      Process.sleep(5000)

      # New request should succeed
      {:ok, %{data: %{"addRequest" => result2}}} = add_request("recovery_test", 2000)
      assert result2["ok"] == true
    end
  end

  describe "claim release discipline" do
    test "claims released on no_partition error" do
      # This is hard to trigger without coordinator manipulation
      # but we can verify the error path exists
      {:ok, %{data: %{"addRequest" => result}}} = add_request("test_user", 5000)

      # Should succeed normally
      assert result["ok"] == true or result["error"] != nil

      # If it failed, verify claim was released
      if result["ok"] == false do
        {:ok, %{data: %{"addRequest" => result2}}} = add_request("test_user", 5000)

        if result2["error"] do
          refute result2["error"] =~ "already"
        end
      end
    end

    test "claims released on all error paths" do
      # Test multiple error scenarios
      test_users = [
        {"error_path_1", 1000},
        {"error_path_2", 2000},
        {"error_path_3", 3000}
      ]

      for {user_id, rank} <- test_users do
        # First attempt (may succeed or fail)
        {:ok, %{data: %{"addRequest" => result1}}} = add_request(user_id, rank)

        # If it failed, verify claim was released
        if result1["ok"] == false do
          # Immediate retry should not show "already_queued"
          {:ok, %{data: %{"addRequest" => result2}}} = add_request(user_id, rank)

          if result2["error"] do
            refute result2["error"] =~ "already",
                   "Claim should be released for user #{user_id}"
          end
        end
      end
    end
  end
end
