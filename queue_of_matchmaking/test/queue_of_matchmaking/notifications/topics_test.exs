defmodule QueueOfMatchmaking.Notifications.TopicsTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.Notifications.Topics

  describe "topic_for_user/1" do
    test "returns correct topic format" do
      assert Topics.topic_for_user("Player123") == "matchFound:Player123"
    end

    test "handles different user IDs" do
      assert Topics.topic_for_user("user_456") == "matchFound:user_456"
      assert Topics.topic_for_user("abc") == "matchFound:abc"
    end

    test "handles empty string" do
      assert Topics.topic_for_user("") == "matchFound:"
    end
  end
end
