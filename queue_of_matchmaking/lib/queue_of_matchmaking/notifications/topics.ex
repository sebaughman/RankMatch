defmodule QueueOfMatchmaking.Notifications.Topics do
  @moduledoc """
  Topic naming conventions for Absinthe subscriptions.
  """

  @doc """
  Returns the subscription topic for a specific user.
  """
  def topic_for_user(user_id) do
    "matchFound:#{user_id}"
  end
end
