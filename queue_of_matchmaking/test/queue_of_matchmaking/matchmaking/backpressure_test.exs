defmodule QueueOfMatchmaking.Matchmaking.BackpressureTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.Matchmaking.Backpressure
  alias QueueOfMatchmaking.Matchmaking.State

  describe "check_overload/1" do
    test "returns :ok when under all limits" do
      state = build_state(queued_count: 100)
      assert :ok = Backpressure.check_overload(state)
    end

    test "returns error when queued_count exceeds limit" do
      state = build_state(queued_count: 501)
      assert {:error, :overloaded} = Backpressure.check_overload(state)
    end

    test "returns error when queued_count equals limit" do
      state = build_state(queued_count: 500)
      assert :ok = Backpressure.check_overload(state)

      state = build_state(queued_count: 501)
      assert {:error, :overloaded} = Backpressure.check_overload(state)
    end

    test "returns error when message queue exceeds limit" do
      state = build_state(queued_count: 10)

      # Flood the process mailbox
      self_pid = self()
      Enum.each(1..150, fn _ -> send(self_pid, :test_message) end)

      assert {:error, :overloaded} = Backpressure.check_overload(state)

      # Clean up mailbox
      flush_mailbox()
    end

    test "returns :ok when message queue is at limit" do
      state = build_state(queued_count: 10)

      # Send exactly 100 messages (the limit)
      self_pid = self()
      Enum.each(1..100, fn _ -> send(self_pid, :test_message) end)

      assert :ok = Backpressure.check_overload(state)

      # Clean up mailbox
      flush_mailbox()
    end

    test "returns error when both limits exceeded" do
      state = build_state(queued_count: 501)

      # Also flood mailbox
      self_pid = self()
      Enum.each(1..150, fn _ -> send(self_pid, :test_message) end)

      assert {:error, :overloaded} = Backpressure.check_overload(state)

      # Clean up mailbox
      flush_mailbox()
    end

    test "handles zero queued_count" do
      state = build_state(queued_count: 0)
      assert :ok = Backpressure.check_overload(state)
    end
  end

  # -- Helpers --

  defp build_state(opts) do
    queued_count = Keyword.get(opts, :queued_count, 0)

    config = %{
      backpressure: [
        message_queue_limit: 100,
        queued_count_limit: 500
      ]
    }

    State.new("test-partition", 0, 1000, config)
    |> Map.put(:queued_count, queued_count)
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end
