defmodule QueueOfMatchmaking.Matchmaking.NearestTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.Matchmaking.{Nearest, State}

  describe "peek_best_opponent/4" do
    setup do
      config = %{max_scan_ranks: 50}
      state = State.new("test-partition", 0, 10000, config)
      {:ok, state: state, config: config}
    end

    test "returns nil when no ranks are queued", %{state: state} do
      requester = {"user1", 1000, 100}
      assert Nearest.peek_best_opponent(state, requester, 100, "user1") == nil
    end

    test "finds opponent at same rank", %{state: state} do
      state = State.enqueue(state, {"user1", 1000, 100})
      state = State.enqueue(state, {"user2", 1000, 200})

      requester = {"user1", 1000, 100}
      opponent = Nearest.peek_best_opponent(state, requester, 0, "user1")

      assert opponent == {"user2", 1000, 200}
    end

    test "excludes requester's user_id at same rank", %{state: state} do
      state = State.enqueue(state, {"user1", 1000, 100})

      requester = {"user1", 1000, 100}
      opponent = Nearest.peek_best_opponent(state, requester, 100, "user1")

      assert opponent == nil
    end

    test "finds closest opponent by rank difference", %{state: state} do
      state = State.enqueue(state, {"user1", 1000, 100})
      state = State.enqueue(state, {"user2", 1005, 200})
      state = State.enqueue(state, {"user3", 990, 300})

      requester = {"user1", 1000, 100}
      opponent = Nearest.peek_best_opponent(state, requester, 20, "user1")

      assert opponent == {"user2", 1005, 200}
    end

    test "prefers lower rank when diff is equal", %{state: state} do
      state = State.enqueue(state, {"user1", 1000, 100})
      state = State.enqueue(state, {"user2", 1010, 200})
      state = State.enqueue(state, {"user3", 990, 200})

      requester = {"user1", 1000, 100}
      opponent = Nearest.peek_best_opponent(state, requester, 20, "user1")

      assert opponent == {"user3", 990, 200}
    end

    test "prefers older enq_ms when diff and rank are equal", %{state: state} do
      state = State.enqueue(state, {"user1", 1000, 100})
      state = State.enqueue(state, {"user3", 1010, 150})
      state = State.enqueue(state, {"user2", 1010, 200})

      requester = {"user1", 1000, 100}
      opponent = Nearest.peek_best_opponent(state, requester, 20, "user1")

      assert opponent == {"user3", 1010, 150}
    end

    test "prefers lexicographically smaller user_id as final tie-breaker", %{state: state} do
      state = State.enqueue(state, {"user1", 1000, 100})
      state = State.enqueue(state, {"userA", 1010, 200})
      state = State.enqueue(state, {"userB", 1010, 200})

      requester = {"user1", 1000, 100}
      opponent = Nearest.peek_best_opponent(state, requester, 20, "user1")

      assert opponent == {"userA", 1010, 200}
    end

    test "respects allowed_diff limit", %{state: state} do
      state = State.enqueue(state, {"user1", 1000, 100})
      state = State.enqueue(state, {"user2", 1050, 200})
      state = State.enqueue(state, {"user3", 950, 300})

      requester = {"user1", 1000, 100}
      opponent = Nearest.peek_best_opponent(state, requester, 30, "user1")

      assert opponent == nil
    end

    test "only peeks head of each rank queue", %{state: state} do
      state = State.enqueue(state, {"user1", 1000, 100})
      state = State.enqueue(state, {"user3", 1010, 200})
      state = State.enqueue(state, {"user2", 1010, 500})

      requester = {"user1", 1000, 100}
      opponent = Nearest.peek_best_opponent(state, requester, 20, "user1")

      assert opponent == {"user3", 1010, 200}
    end

    test "respects max_scan_ranks limit", %{state: state} do
      config = %{max_scan_ranks: 3}
      state = %{state | config: config}

      state = State.enqueue(state, {"user1", 1000, 100})
      state = State.enqueue(state, {"user2", 1001, 200})
      state = State.enqueue(state, {"user3", 1002, 300})
      state = State.enqueue(state, {"user4", 1003, 400})
      state = State.enqueue(state, {"user5", 1010, 500})

      requester = {"user1", 1000, 100}
      opponent = Nearest.peek_best_opponent(state, requester, 100, "user1")

      assert opponent != nil
      {_user_id, rank, _enq_ms} = opponent
      assert rank <= 1003
    end

    test "handles sparse rank distribution", %{state: state} do
      state = State.enqueue(state, {"user1", 1000, 100})
      state = State.enqueue(state, {"user2", 1100, 200})
      state = State.enqueue(state, {"user3", 900, 200})

      requester = {"user1", 1000, 100}
      opponent = Nearest.peek_best_opponent(state, requester, 150, "user1")

      assert opponent == {"user3", 900, 200}
    end

    test "handles edge case with only requester in queue", %{state: state} do
      state = State.enqueue(state, {"user1", 1000, 100})

      requester = {"user1", 1000, 100}
      opponent = Nearest.peek_best_opponent(state, requester, 100, "user1")

      assert opponent == nil
    end
  end

  describe "take_best_opponent/2" do
    setup do
      config = %{max_scan_ranks: 50}
      state = State.new("test-partition", 0, 10000, config)
      {:ok, state: state}
    end

    test "successfully removes opponent when head matches", %{state: state} do
      state = State.enqueue(state, {"user1", 1000, 100})
      state = State.enqueue(state, {"user2", 1010, 200})

      opponent = {"user2", 1010, 200}
      assert {:ok, new_state} = Nearest.take_best_opponent(state, opponent)
      assert new_state.queued_count == 1
      assert State.peek_head(new_state, 1010) == nil
    end

    test "returns error when opponent is not at head", %{state: state} do
      state = State.enqueue(state, {"user1", 1010, 100})
      state = State.enqueue(state, {"user2", 1010, 200})

      opponent = {"user2", 1010, 200}
      assert {:error, :mismatch} = Nearest.take_best_opponent(state, opponent)
    end

    test "returns error when opponent rank is empty", %{state: state} do
      opponent = {"user1", 1010, 100}
      assert {:error, :mismatch} = Nearest.take_best_opponent(state, opponent)
    end

    test "handles concurrent modification race condition", %{state: state} do
      state = State.enqueue(state, {"user1", 1010, 100})
      state = State.enqueue(state, {"user2", 1010, 200})

      opponent = {"user1", 1010, 100}
      assert {:ok, new_state} = Nearest.take_best_opponent(state, opponent)

      assert {:error, :mismatch} = Nearest.take_best_opponent(new_state, opponent)
    end
  end
end
