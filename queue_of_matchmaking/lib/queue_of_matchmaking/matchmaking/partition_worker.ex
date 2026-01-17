defmodule QueueOfMatchmaking.Matchmaking.PartitionWorker do
  @moduledoc """
  GenServer managing a single partition's matchmaking queue.
  Handles immediate matching on enqueue and periodic tick-based widening.
  """

  use GenServer

  alias QueueOfMatchmaking.Matchmaking.{State, Nearest, Widening, Backpressure}
  alias QueueOfMatchmaking.Notifications.MatchPublisher
  alias QueueOfMatchmaking.Index.UserIndex

  @doc """
  Starts a partition worker.
  """
  def start_link(opts) do
    partition_id = Keyword.fetch!(opts, :partition_id)
    range_start = Keyword.fetch!(opts, :range_start)
    range_end = Keyword.fetch!(opts, :range_end)
    config = Keyword.fetch!(opts, :config)
    name = Keyword.get(opts, :name)

    GenServer.start_link(__MODULE__, {partition_id, range_start, range_end, config}, name: name)
  end

  @doc """
  Enqueues a user into the partition for matchmaking.
  """
  def enqueue(pid, user_id, rank, timeout \\ nil) do
    timeout = timeout || Application.fetch_env!(:queue_of_matchmaking, :enqueue_timeout_ms)
    GenServer.call(pid, {:enqueue, user_id, rank}, timeout)
  end

  @impl true
  def init({partition_id, range_start, range_end, config}) do
    state = State.new(partition_id, range_start, range_end, config)
    schedule_tick(config.tick_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, user_id, rank}, _from, state) do
    with :ok <- Backpressure.check_overload(state),
         :ok <- validate_rank_in_range(rank, state) do
      ticket = {user_id, rank, System.monotonic_time(:millisecond)}
      {reply, new_state} = attempt_immediate_match(ticket, state)
      {:reply, reply, new_state}
    else
      {:error, :overloaded} ->
        {:reply, {:error, :overloaded}, state}

      {:error, :out_of_range} ->
        {:reply, {:error, :out_of_range}, state}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    new_state = process_tick(state)
    schedule_tick(state.config.tick_interval_ms)
    {:noreply, new_state}
  end

  # -- Enqueue flow --

  defp validate_rank_in_range(rank, state) do
    if rank >= state.range_start and rank <= state.range_end do
      :ok
    else
      {:error, :out_of_range}
    end
  end

  defp attempt_immediate_match({user_id, _rank, _enq} = ticket, state) do
    case Nearest.peek_best_opponent(state, ticket, 0, user_id) do
      nil ->
        {:ok, State.enqueue(state, ticket)}

      opponent_ticket ->
        case Nearest.take_best_opponent(state, opponent_ticket) do
          {:ok, new_state} ->
            finalize_match(ticket, opponent_ticket)
            {:ok, new_state}

          {:error, :mismatch} ->
            {:ok, State.enqueue(state, ticket)}
        end
    end
  end

  # -- Tick flow --

  defp process_tick(state) do
    process_best_attempts(state, 0)
  end

  defp process_best_attempts(state, attempts) do
    if attempts >= state.config.max_tick_attempts do
      state
    else
      case find_global_best_pair(state) do
        nil ->
          state

        {requester_ticket, opponent_ticket} ->
          new_state = attempt_match_from_tick(state, requester_ticket, opponent_ticket)
          process_best_attempts(new_state, attempts + 1)
      end
    end
  end

  defp find_global_best_pair(state) do
    ranks = :gb_sets.to_list(state.non_empty_ranks)

    Enum.reduce(ranks, nil, fn rank, best ->
      case State.peek_head(state, rank) do
        nil ->
          best

        {user_id, _r, enq_ms} = requester ->
          age_ms = System.monotonic_time(:millisecond) - enq_ms
          allowed = Widening.allowed_diff(age_ms, state.config)

          case Nearest.peek_best_opponent(state, requester, allowed, user_id) do
            nil ->
              best

            opponent ->
              diff = abs(elem(opponent, 1) - elem(requester, 1))
              choose_better_pair(best, {requester, opponent, diff})
          end
      end
    end)
    |> case do
      nil -> nil
      {req, opp, _diff} -> {req, opp}
    end
  end

  defp choose_better_pair(nil, cand), do: cand

  defp choose_better_pair({b_req, b_opp, b_diff} = best, {c_req, c_opp, c_diff} = cand) do
    {_b_uid, _b_rank, b_enq} = b_req
    {c_uid, _c_rank, c_enq} = c_req

    cond do
      c_diff < b_diff -> cand
      c_diff > b_diff -> best
      c_enq < b_enq -> cand
      c_enq > b_enq -> best
      c_uid < elem(b_req, 0) -> cand
      true -> best
    end
  end

  defp attempt_match_from_tick(state, {_, req_rank, _} = requester_ticket, opponent_ticket) do
    case State.dequeue_head_if_matches(state, req_rank, requester_ticket) do
      {:ok, state_after_req} ->
        case Nearest.take_best_opponent(state_after_req, opponent_ticket) do
          {:ok, final_state} ->
            finalize_match(requester_ticket, opponent_ticket)
            final_state

          {:error, :mismatch} ->
            State.enqueue_front(state_after_req, requester_ticket)
        end

      {:error, :mismatch} ->
        state
    end
  end

  # -- Match finalization --

  defp finalize_match({user1_id, _, _} = ticket1, {user2_id, _, _} = ticket2) do
    UserIndex.release(user1_id)
    UserIndex.release(user2_id)
    MatchPublisher.publish_match(ticket1, ticket2)
  end

  # -- Helpers --

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end
end
