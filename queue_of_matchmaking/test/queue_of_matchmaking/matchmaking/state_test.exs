defmodule QueueOfMatchmaking.Matchmaking.StateTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.Matchmaking.State

  describe "new/4" do
    test "creates empty state with correct fields" do
      state = State.new("p-0000-0499", 0, 499, %{})

      assert state.partition_id == "p-0000-0499"
      assert state.range_start == 0
      assert state.range_end == 499
      assert state.queues_by_rank == %{}
      assert :gb_sets.is_empty(state.non_empty_ranks)
      assert state.queued_count == 0
      assert state.tick_cursor == nil
    end
  end

  describe "enqueue/2" do
    test "enqueues ticket to new rank" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket = {"user1", 100, 1000}

      new_state = State.enqueue(state, ticket)

      assert new_state.queued_count == 1
      assert State.rank_present?(new_state, 100)
      assert State.peek_head(new_state, 100) == ticket
    end

    test "enqueues multiple tickets to same rank (FIFO)" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket1 = {"user1", 100, 1000}
      ticket2 = {"user2", 100, 2000}

      new_state =
        state
        |> State.enqueue(ticket1)
        |> State.enqueue(ticket2)

      assert new_state.queued_count == 2
      assert State.peek_head(new_state, 100) == ticket1
    end

    test "enqueues tickets to different ranks" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket1 = {"user1", 100, 1000}
      ticket2 = {"user2", 200, 2000}

      new_state =
        state
        |> State.enqueue(ticket1)
        |> State.enqueue(ticket2)

      assert new_state.queued_count == 2
      assert State.rank_present?(new_state, 100)
      assert State.rank_present?(new_state, 200)
    end
  end

  describe "enqueue_front/2" do
    test "enqueues ticket to head of existing queue" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket1 = {"user1", 100, 1000}
      ticket2 = {"user2", 100, 2000}

      new_state =
        state
        |> State.enqueue(ticket1)
        |> State.enqueue_front(ticket2)

      assert new_state.queued_count == 2
      assert State.peek_head(new_state, 100) == ticket2
    end

    test "enqueues ticket to head of empty rank" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket = {"user1", 100, 1000}

      new_state = State.enqueue_front(state, ticket)

      assert new_state.queued_count == 1
      assert State.rank_present?(new_state, 100)
      assert State.peek_head(new_state, 100) == ticket
    end
  end

  describe "dequeue_head/2" do
    test "dequeues head ticket from rank" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket = {"user1", 100, 1000}

      new_state = State.enqueue(state, ticket)
      {dequeued, final_state} = State.dequeue_head(new_state, 100)

      assert dequeued == ticket
      assert final_state.queued_count == 0
      refute State.rank_present?(final_state, 100)
    end

    test "dequeues head and leaves remaining tickets" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket1 = {"user1", 100, 1000}
      ticket2 = {"user2", 100, 2000}

      new_state =
        state
        |> State.enqueue(ticket1)
        |> State.enqueue(ticket2)

      {dequeued, final_state} = State.dequeue_head(new_state, 100)

      assert dequeued == ticket1
      assert final_state.queued_count == 1
      assert State.rank_present?(final_state, 100)
      assert State.peek_head(final_state, 100) == ticket2
    end

    test "returns nil for non-existent rank" do
      state = State.new("p-0000-0499", 0, 499, %{})

      {dequeued, final_state} = State.dequeue_head(state, 100)

      assert dequeued == nil
      assert final_state == state
    end

    test "returns nil for empty rank queue" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket = {"user1", 100, 1000}

      new_state = State.enqueue(state, ticket)
      {_dequeued, intermediate_state} = State.dequeue_head(new_state, 100)
      {dequeued, final_state} = State.dequeue_head(intermediate_state, 100)

      assert dequeued == nil
      assert final_state == intermediate_state
    end
  end

  describe "dequeue_head_if_matches/3" do
    test "dequeues when head matches expected ticket" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket = {"user1", 100, 1000}

      new_state = State.enqueue(state, ticket)
      result = State.dequeue_head_if_matches(new_state, 100, ticket)

      assert {:ok, final_state} = result
      assert final_state.queued_count == 0
      refute State.rank_present?(final_state, 100)
    end

    test "returns mismatch when head does not match" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket1 = {"user1", 100, 1000}
      ticket2 = {"user2", 100, 2000}

      new_state = State.enqueue(state, ticket1)
      result = State.dequeue_head_if_matches(new_state, 100, ticket2)

      assert {:error, :mismatch} = result
    end

    test "returns mismatch for non-existent rank" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket = {"user1", 100, 1000}

      result = State.dequeue_head_if_matches(state, 100, ticket)

      assert {:error, :mismatch} = result
    end

    test "returns mismatch for empty rank queue" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket1 = {"user1", 100, 1000}
      ticket2 = {"user2", 100, 2000}

      new_state = State.enqueue(state, ticket1)
      {_dequeued, intermediate_state} = State.dequeue_head(new_state, 100)
      result = State.dequeue_head_if_matches(intermediate_state, 100, ticket2)

      assert {:error, :mismatch} = result
    end
  end

  describe "peek_head/2" do
    test "returns head ticket without removing it" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket = {"user1", 100, 1000}

      new_state = State.enqueue(state, ticket)
      peeked = State.peek_head(new_state, 100)

      assert peeked == ticket
      assert new_state.queued_count == 1
      assert State.rank_present?(new_state, 100)
    end

    test "returns nil for non-existent rank" do
      state = State.new("p-0000-0499", 0, 499, %{})

      peeked = State.peek_head(state, 100)

      assert peeked == nil
    end
  end

  describe "rank_present?/2" do
    test "returns true for rank with tickets" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket = {"user1", 100, 1000}

      new_state = State.enqueue(state, ticket)

      assert State.rank_present?(new_state, 100)
    end

    test "returns false for rank without tickets" do
      state = State.new("p-0000-0499", 0, 499, %{})

      refute State.rank_present?(state, 100)
    end

    test "returns false after all tickets dequeued" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket = {"user1", 100, 1000}

      new_state = State.enqueue(state, ticket)
      {_dequeued, final_state} = State.dequeue_head(new_state, 100)

      refute State.rank_present?(final_state, 100)
    end
  end

  describe "non_empty_ranks/1" do
    test "returns empty set for new state" do
      state = State.new("p-0000-0499", 0, 499, %{})

      ranks = State.non_empty_ranks(state)

      assert :gb_sets.is_empty(ranks)
    end

    test "returns set with enqueued ranks" do
      state = State.new("p-0000-0499", 0, 499, %{})
      ticket1 = {"user1", 100, 1000}
      ticket2 = {"user2", 200, 2000}

      new_state =
        state
        |> State.enqueue(ticket1)
        |> State.enqueue(ticket2)

      ranks = State.non_empty_ranks(new_state)

      assert :gb_sets.is_member(100, ranks)
      assert :gb_sets.is_member(200, ranks)
      assert :gb_sets.size(ranks) == 2
    end
  end

  describe "queued_count invariant" do
    test "maintains accurate count through enqueue/dequeue operations" do
      state = State.new("p-0000-0499", 0, 499, %{})

      # Enqueue 3 tickets
      state =
        state
        |> State.enqueue({"user1", 100, 1000})
        |> State.enqueue({"user2", 100, 2000})
        |> State.enqueue({"user3", 200, 3000})

      assert state.queued_count == 3

      # Dequeue 1
      {_ticket, state} = State.dequeue_head(state, 100)
      assert state.queued_count == 2

      # Enqueue front
      state = State.enqueue_front(state, {"user4", 100, 4000})
      assert state.queued_count == 3

      # Dequeue all from rank 100
      {_ticket, state} = State.dequeue_head(state, 100)
      assert state.queued_count == 2

      {_ticket, state} = State.dequeue_head(state, 100)
      assert state.queued_count == 1

      # Dequeue last ticket
      {_ticket, state} = State.dequeue_head(state, 200)
      assert state.queued_count == 0
    end
  end

  describe "rollback scenario" do
    test "enqueue_front preserves fairness after failed match" do
      state = State.new("p-0000-0499", 0, 499, %{})
      requester = {"user1", 100, 1000}
      other = {"user2", 100, 2000}

      # Simulate: requester arrives, then other arrives
      state =
        state
        |> State.enqueue(requester)
        |> State.enqueue(other)

      # Peek shows requester at head
      assert State.peek_head(state, 100) == requester

      # Simulate: we peek requester, try to match, fail, need to rollback
      # Remove requester
      {removed, state} = State.dequeue_head(state, 100)
      assert removed == requester

      # Now other is at head
      assert State.peek_head(state, 100) == other

      # Rollback: put requester back at head
      state = State.enqueue_front(state, requester)

      # Requester should be back at head
      assert State.peek_head(state, 100) == requester
      assert state.queued_count == 2
    end
  end
end
