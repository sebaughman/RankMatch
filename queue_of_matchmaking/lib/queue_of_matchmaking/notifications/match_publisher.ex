defmodule QueueOfMatchmaking.Notifications.MatchPublisher do
  @moduledoc """
  Publishes match events to Absinthe subscriptions.
  Best-effort delivery; duplicates possible in retry scenarios.
  """

  alias QueueOfMatchmaking.Notifications.Topics

  @doc """
  Publishes a match event to both users' subscription topics.
  """
  def publish_match({user1_id, rank1, _enq1}, {user2_id, rank2, _enq2}) do
    payload = %{
      users: [
        %{userId: user1_id, userRank: rank1},
        %{userId: user2_id, userRank: rank2}
      ]
    }

    publish_to_user(user1_id, payload)
    publish_to_user(user2_id, payload)

    :ok
  end

  defp publish_to_user(user_id, payload) do
    topic = Topics.topic_for_user(user_id)

    Absinthe.Subscription.publish(
      QueueOfMatchmaking.Web.Endpoint,
      payload,
      matchFound: topic
    )
  end
end
