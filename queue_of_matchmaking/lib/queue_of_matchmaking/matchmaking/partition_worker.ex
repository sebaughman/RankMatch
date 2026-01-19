defmodule QueueOfMatchmaking.Matchmaking.PartitionWorker do
  @moduledoc """
  GenServer managing a single partition's matchmaking queue.
  Handles immediate matching on enqueue and periodic tick-based widening.

  ## Epoch-Scoped Identity

  Partition workers are registered in Horde.Registry using epoch-scoped keys:
  {:partition, epoch, partition_id}. This enables future warm-up scenarios where
  multiple epochs can run side-by-side without process name collisions.
  """

  use GenServer
  require Logger

  alias QueueOfMatchmaking.Matchmaking.{State, Nearest, Widening, Backpressure, Helpers}
  alias QueueOfMatchmaking.Notifications.MatchPublisher
  alias QueueOfMatchmaking.Index.UserIndex
  alias QueueOfMatchmaking.Cluster.Router
  alias QueueOfMatchmaking.Config

  @doc """
  Starts a partition worker.
  """
  def start_link(opts) do
    partition_id = Keyword.fetch!(opts, :partition_id)
    range_start = Keyword.fetch!(opts, :range_start)
    range_end = Keyword.fetch!(opts, :range_end)
    epoch = Keyword.fetch!(opts, :epoch)
    config = Keyword.fetch!(opts, :config)
    name = Keyword.get(opts, :name)

    GenServer.start_link(__MODULE__, {partition_id, range_start, range_end, epoch, config},
      name: name
    )
  end

  @doc """
  Enqueues a user into the partition for matchmaking.
  Accepts an envelope containing epoch, partition_id, user_id, and rank.
  """
  def enqueue(pid, envelope, timeout \\ nil) do
    timeout = timeout || Config.enqueue_timeout_ms()
    GenServer.call(pid, {:enqueue, envelope}, timeout)
  end

  @doc """
  Peeks the best opponent for cross-partition matching.
  Returns {:ok, ticket | nil} or {:error, :epoch_mismatch}.
  """
  def peek_nearest(pid, rank, allowed_diff, exclude_user_id, epoch, timeout \\ nil) do
    timeout = timeout || Config.rpc_timeout_ms()

    GenServer.call(
      pid,
      {:peek_nearest, rank, allowed_diff, exclude_user_id, epoch},
      timeout
    )
  end

  @doc """
  Atomically reserves a specific ticket if still at head of queue.
  Returns {:ok, ticket} or {:error, :not_found | :epoch_mismatch}.
  """
  def reserve(pid, user_id, rank, enq_ms, epoch, timeout \\ nil) do
    timeout = timeout || Config.rpc_timeout_ms()

    GenServer.call(
      pid,
      {:reserve, user_id, rank, enq_ms, epoch},
      timeout
    )
  end

  @impl true
  def init({partition_id, range_start, range_end, epoch, config}) do
    state = State.new(partition_id, range_start, range_end, epoch, config)
    schedule_tick(config.tick_interval_ms)
    Logger.info("Partition started: id=#{partition_id} range=#{range_start}..#{range_end} epoch=#{epoch}")
    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, envelope}, _from, state) do
    with :ok <- validate_epoch(envelope.epoch, state.epoch),
         :ok <- Backpressure.check_overload(state),
         :ok <- validate_rank_in_range(envelope.rank, state) do
      ticket = {envelope.user_id, envelope.rank, System.monotonic_time(:millisecond)}
      {reply, new_state} = attempt_immediate_match(ticket, state)
      {:reply, reply, new_state}
    else
      {:error, :stale_epoch} ->
        {:reply, {:error, :stale_epoch}, state}

      {:error, :overloaded} ->
        {:reply, {:error, :overloaded}, state}

      {:error, :out_of_range} ->
        {:reply, {:error, :out_of_range}, state}
    end
  end

  @impl true
  def handle_call({:peek_nearest, rank, allowed_diff, exclude_user_id, request_epoch}, _from, state) do
    case validate_epoch(request_epoch, state.epoch) do
      {:error, :stale_epoch} ->
        {:reply, {:error, :epoch_mismatch}, state}

      :ok ->
        # Create synthetic requester with realistic timestamp
        synthetic_ticket = {"_peek_", rank, System.monotonic_time(:millisecond)}

        opponent = Nearest.peek_best_opponent(
          state,
          synthetic_ticket,
          allowed_diff,
          exclude_user_id
        )

        {:reply, {:ok, opponent}, state}
    end
  end

  @impl true
  def handle_call({:reserve, user_id, rank, enq_ms, request_epoch}, _from, state) do
    case validate_epoch(request_epoch, state.epoch) do
      {:error, :stale_epoch} ->
        {:reply, {:error, :epoch_mismatch}, state}

      :ok ->
        ticket = {user_id, rank, enq_ms}

        case State.dequeue_head_if_matches(state, rank, ticket) do
          {:ok, new_state} ->
            {:reply, {:ok, ticket}, new_state}

          {:error, :mismatch} ->
            {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call(:health_check, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    # Logger.info("Tick: partition=#{state.partition_id} queued=#{state.queued_count}")
    new_state = process_tick(state)
    schedule_tick(state.config.tick_interval_ms)
    {:noreply, new_state}
  end

  # -- Enqueue flow --

  defp validate_epoch(request_epoch, state_epoch) do
    if request_epoch == state_epoch do
      :ok
    else
      {:error, :stale_epoch}
    end
  end

  defp validate_rank_in_range(rank, state) do
    if rank >= state.range_start and rank <= state.range_end do
      :ok
    else
      {:error, :out_of_range}
    end
  end

  defp attempt_immediate_match({user_id, rank, _enq} = ticket, state) do
    allowed_diff = state.config.immediate_match_allowed_diff || 100

    case Nearest.peek_best_opponent(state, ticket, allowed_diff, user_id) do
      nil ->
        # Logger.info("User enqueued: user_id=#{user_id} rank=#{rank} partition=#{state.partition_id}")
        {:ok, State.enqueue(state, ticket)}

      opponent_ticket ->
        case Nearest.take_best_opponent(state, opponent_ticket) do
          {:ok, new_state} ->
            {opp_user, opp_rank, _} = opponent_ticket
            diff = abs(rank - opp_rank)
            Logger.info("MATCHED (Immediate): user1=#{user_id} rank1=#{rank} user2=#{opp_user} rank2=#{opp_rank} diff=#{diff}")
            finalize_match(ticket, opponent_ticket)
            {:ok, new_state}

          {:error, :mismatch} ->
            Logger.info("User enqueued: user_id=#{user_id} rank=#{rank} partition=#{state.partition_id}")
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

        {requester_ticket, opponent_ticket, opponent_source} ->
          new_state = attempt_match_from_tick(state, requester_ticket, opponent_ticket, opponent_source)
          process_best_attempts(new_state, attempts + 1)
      end
    end
  end

  defp find_global_best_pair(state) do
    ranks = :gb_sets.to_list(state.non_empty_ranks)

    best = Enum.reduce(ranks, nil, fn rank, best ->
      case State.peek_head(state, rank) do
        nil ->
          best

        {user_id, _r, enq_ms} = requester ->
          age_ms = System.monotonic_time(:millisecond) - enq_ms
          allowed = Widening.allowed_diff(age_ms, state.config)

          local_opponent = Nearest.peek_best_opponent(state, requester, allowed, user_id)
          adjacent_candidates = peek_adjacent_for_tick(requester, allowed, state)
          all_candidates = Helpers.combine_candidates(local_opponent, adjacent_candidates)

          Helpers.choose_best(requester, all_candidates, best)
      end
    end)


    case best do
      nil -> nil
      {req, opp, source, _diff} -> {req, opp, source}
    end
  end

  defp peek_adjacent_for_tick({user_id, rank, _}, allowed_diff, state) do
    # Optimization: only query adjacent partitions if allowed_diff could cross boundaries
    left_pid = if rank - allowed_diff < state.range_start do
      {left, _} = Router.adjacent_partitions(rank)
      left
    else
      nil
    end

    right_pid = if rank + allowed_diff > state.range_end do
      {_, right} = Router.adjacent_partitions(rank)
      right
    else
      nil
    end

    peek_adjacent_partitions(left_pid, right_pid, {user_id, rank, 0}, allowed_diff, state.epoch)
  end

  defp peek_adjacent_partitions(left_pid, right_pid, {user_id, rank, _}, allowed_diff, epoch) do
    timeout = Config.rpc_timeout_ms()

    left_result = safe_peek(left_pid, rank, allowed_diff, user_id, epoch, timeout)
    right_result = safe_peek(right_pid, rank, allowed_diff, user_id, epoch, timeout)

    [left_result, right_result]
    |> Enum.reject(&is_nil/1)
  end

  defp safe_peek(nil, _rank, _allowed_diff, _exclude, _epoch, _timeout), do: nil

  defp safe_peek(pid, rank, allowed_diff, exclude_user_id, epoch, timeout) do
    try do
      case __MODULE__.peek_nearest(pid, rank, allowed_diff, exclude_user_id, epoch, timeout) do
        {:ok, nil} -> nil
        {:ok, ticket} -> {pid, ticket}
        {:error, :epoch_mismatch} -> nil
        {:error, _} -> nil
      end
    catch
      :exit, _ ->
        Logger.debug("Cross-partition peek RPC failed (timeout/noproc)")
        nil
    end
  end

  defp attempt_match_from_tick(state, {_, req_rank, _} = requester_ticket, opponent_ticket, opponent_source) do
    case State.dequeue_head_if_matches(state, req_rank, requester_ticket) do
      {:ok, state_after_req} ->
        case opponent_source do
          :local ->
            finalize_local_opponent(state_after_req, requester_ticket, opponent_ticket)

          {:remote, remote_pid} ->
            finalize_remote_opponent(state_after_req, requester_ticket, opponent_ticket, remote_pid, state.epoch)
        end

      {:error, :mismatch} ->
        state
    end
  end

  defp finalize_local_opponent(state, requester_ticket, opponent_ticket) do
    case Nearest.take_best_opponent(state, opponent_ticket) do
      {:ok, final_state} ->
        {req_user, req_rank, _} = requester_ticket
        {opp_user, opp_rank, _} = opponent_ticket
        diff = abs(req_rank - opp_rank)
        Logger.info("MATCHED (tick): user1=#{req_user} rank1=#{req_rank} user2=#{opp_user} rank2=#{opp_rank} diff=#{diff}")
        finalize_match(requester_ticket, opponent_ticket)
        final_state

      {:error, :mismatch} ->
        Logger.debug("Tick local opponent mismatch, re-queueing requester")
        State.enqueue_front(state, requester_ticket)
    end
  end

  defp finalize_remote_opponent(state, requester_ticket, opponent_ticket, remote_pid, epoch) do
    {opp_user, opp_rank, opp_enq} = opponent_ticket

    case reserve_remote_for_tick(remote_pid, opp_user, opp_rank, opp_enq, epoch) do
      {:ok, _ticket} ->
        {req_user, req_rank, _} = requester_ticket
        diff = abs(req_rank - opp_rank)
        Logger.info("MATCHED (tick): user1=#{req_user} rank1=#{req_rank} user2=#{opp_user} rank2=#{opp_rank} diff=#{diff}")
        finalize_match(requester_ticket, opponent_ticket)
        state

      {:error, _reason} ->
        Logger.debug("Tick remote reserve failed, re-queueing requester")
        State.enqueue_front(state, requester_ticket)
    end
  end

  defp reserve_remote_for_tick(remote_pid, user_id, rank, enq_ms, epoch) do
    try do
      __MODULE__.reserve(remote_pid, user_id, rank, enq_ms, epoch)
    catch
      :exit, _ ->
        Logger.debug("Tick remote reserve RPC failed")
        {:error, :rpc_failed}
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
