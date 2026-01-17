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
        %{user_id: user1_id, user_rank: rank1},
        %{user_id: user2_id, user_rank: rank2}
      ]
    }

    publish_to_user(user1_id, payload)
    publish_to_user(user2_id, payload)

    :ok
  end

  defp publish_to_user(user_id, payload) do
    topic = Topics.topic_for_user(user_id)

    try do
      Absinthe.Subscription.publish(
        QueueOfMatchmaking.Web.Endpoint,
        payload,
        match_found: topic
      )
    rescue
      ArgumentError ->
        :ok
    end
  end
end
