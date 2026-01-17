defmodule QueueOfMatchmaking.GraphqlCase do
  @moduledoc """
  Shared helpers for GraphQL integration tests.
  Provides utilities for HTTP mutations and WebSocket subscriptions.
  """

  use ExUnit.Case
  import Phoenix.ChannelTest
  import Absinthe.Phoenix.SubscriptionTest

  @endpoint QueueOfMatchmaking.Web.Endpoint

  @doc """
  Generates a unique user ID for testing.
  """
  def unique_user_id(prefix \\ "player") do
    "#{prefix}_#{System.unique_integer([:positive])}_#{:rand.uniform(1_000_000)}"
  end

  @doc """
  Executes a GraphQL mutation via Absinthe.run.
  """
  def run_mutation(mutation_doc, variables \\ %{}) do
    Absinthe.run(mutation_doc, QueueOfMatchmaking.Graphql.Schema, variables: variables)
  end

  @doc """
  Executes addRequest mutation and returns the result.
  """
  def add_request(user_id, rank) do
    mutation = """
    mutation($userId: String!, $rank: Int!) {
      addRequest(userId: $userId, rank: $rank) {
        ok
        error
      }
    }
    """

    run_mutation(mutation, %{"userId" => user_id, "rank" => rank})
  end

  @doc """
  Sets up a GraphQL subscription for matchFound.
  Returns {socket, subscription_id}.
  """
  def subscribe_to_match(user_id) do
    {:ok, socket} = connect(QueueOfMatchmaking.Web.Socket, %{})
    {:ok, socket} = join_absinthe(socket)

    subscription = """
    subscription($userId: String!) {
      matchFound(userId: $userId) {
        users {
          userId
          userRank
        }
      }
    }
    """

    ref = push_doc(socket, subscription, variables: %{"userId" => user_id})

    assert_reply(ref, :ok, %{subscriptionId: subscription_id}, 1000)

    {socket, subscription_id}
  end

  @doc """
  Asserts that a match notification is received on the subscription.
  Returns the match payload.
  """
  def assert_match_received(expected_subscription_id, timeout \\ 150) do
    assert_push("subscription:data", push_data, timeout)

    assert %{
             result: %{data: %{"matchFound" => %{"users" => users}}},
             subscriptionId: _subscription_id
           } = push_data

    assert length(users) == 2
    users
  end

  @doc """
  Asserts that no match notification is received within the timeout.
  """
  def refute_match_received(timeout \\ 40) do
    refute_push("subscription:data", _, timeout)
  end

  @doc """
  Extracts user IDs from a match payload.
  """
  def extract_user_ids(users) do
    Enum.map(users, fn user -> user["userId"] end) |> Enum.sort()
  end

  @doc """
  Asserts that the mutation succeeded.
  """
  def assert_request_ok(result) do
    assert {:ok, %{data: %{"addRequest" => %{"ok" => true, "error" => nil}}}} = result
  end

  @doc """
  Asserts that the mutation failed with a specific error.
  """
  def assert_request_error(result, expected_error) do
    assert {:ok, %{data: %{"addRequest" => %{"ok" => false, "error" => error}}}} = result
    assert error == expected_error
  end

  @doc """
  Flushes all pending messages from the process mailbox.
  Useful for cleaning up between tests to prevent message leakage.
  """
  def flush_all_messages do
    receive do
      _ -> flush_all_messages()
    after
      0 -> :ok
    end
  end

  @doc """
  Waits for the Phoenix endpoint to be ready.
  Polls with exponential backoff to ensure WebSocket/subscription infrastructure is initialized.
  """
  def wait_for_endpoint(retries \\ 50) do
    # Check if endpoint process is alive and registered
    case Process.whereis(@endpoint) do
      nil ->
        if retries > 0 do
          Process.sleep(10)
          wait_for_endpoint(retries - 1)
        else
          raise "Endpoint not ready after #{50 * 10}ms"
        end

      _pid ->
        # Give a small additional delay for subscription infrastructure
        Process.sleep(50)
        :ok
    end
  end
end
