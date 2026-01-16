defmodule QueueOfMatchmaking.Matchmaking.State do
  @moduledoc """
  Pure data structure for partition matchmaking state.
  Manages rank queues and supports safe peeking/removal helpers.
  """

  defstruct [
    :partition_id,
    :range_start,
    :range_end,
    :queues_by_rank,
    :non_empty_ranks,
    :queued_count,
    :tick_cursor,
    :config
  ]

  @doc """
  Creates a new partition state.
  """
  def new(partition_id, range_start, range_end, config) do
    %__MODULE__{
      partition_id: partition_id,
      range_start: range_start,
      range_end: range_end,
      queues_by_rank: %{},
      non_empty_ranks: :gb_sets.empty(),
      queued_count: 0,
      tick_cursor: nil,
      config: config
    }
  end

  @doc """
  Enqueues a ticket at the tail of its rank queue.
  """
  def enqueue(state, {_, rank, _} = ticket) do
    queue = Map.get(state.queues_by_rank, rank, :queue.new())
    updated_queue = :queue.in(ticket, queue)

    %{
      state
      | queues_by_rank: Map.put(state.queues_by_rank, rank, updated_queue),
        non_empty_ranks: :gb_sets.add(rank, state.non_empty_ranks),
        queued_count: state.queued_count + 1
    }
  end

  @doc """
  Enqueues a ticket at the head of its rank queue.
  """
  def enqueue_front(state, {_, rank, _} = ticket) do
    queue = Map.get(state.queues_by_rank, rank, :queue.new())
    updated_queue = :queue.in_r(ticket, queue)

    %{
      state
      | queues_by_rank: Map.put(state.queues_by_rank, rank, updated_queue),
        non_empty_ranks: :gb_sets.add(rank, state.non_empty_ranks),
        queued_count: state.queued_count + 1
    }
  end

  @doc """
  Removes and returns the head ticket from a rank queue.
  Returns {nil, state} if rank has no queued tickets.
  """
  def dequeue_head(state, rank) do
    case Map.get(state.queues_by_rank, rank) do
      nil ->
        {nil, state}

      queue ->
        case :queue.out(queue) do
          {:empty, _} ->
            {nil, state}

          {{:value, ticket}, rest_queue} ->
            state =
              state
              |> update_rank_queue_after_pop(rank, rest_queue)
              |> dec_queued_count()

            {ticket, state}
        end
    end
  end

  defp update_rank_queue_after_pop(state, rank, rest_queue) do
    if :queue.is_empty(rest_queue) do
      %{
        state
        | queues_by_rank: Map.delete(state.queues_by_rank, rank),
          non_empty_ranks: :gb_sets.delete(rank, state.non_empty_ranks)
      }
    else
      %{
        state
        | queues_by_rank: Map.put(state.queues_by_rank, rank, rest_queue)
      }
    end
  end

  defp dec_queued_count(state) do
    %{state | queued_count: state.queued_count - 1}
  end

  @doc """
  Atomically removes head ticket if it matches expected ticket.
  """
  def dequeue_head_if_matches(state, rank, expected_ticket) do
    case peek_head(state, rank) do
      ^expected_ticket ->
        {_ticket, new_state} = dequeue_head(state, rank)
        {:ok, new_state}

      _ ->
        {:error, :mismatch}
    end
  end

  @doc """
  Returns the head ticket of a rank queue without removing it.
  """
  def peek_head(state, rank) do
    case Map.get(state.queues_by_rank, rank) do
      nil ->
        nil

      queue ->
        case :queue.peek(queue) do
          {:value, ticket} -> ticket
          :empty -> nil
        end
    end
  end

  @doc """
  Returns the head ticket unless it belongs to exclude_user_id.
  If the head is excluded, returns the next ticket (peek-only).
  """
  def peek_head_skipping_user(state, rank, exclude_user_id) do
    case Map.get(state.queues_by_rank, rank) do
      nil ->
        nil

      queue ->
        peek_head_skipping_user_from_queue(queue, exclude_user_id, rank)
    end
  end

  defp peek_head_skipping_user_from_queue(queue, exclude_user_id, rank) do
    case :queue.out(queue) do
      {:empty, _} ->
        nil

      {{:value, {^exclude_user_id, ^rank, _}}, rest_queue} ->
        case :queue.out(rest_queue) do
          {:empty, _} -> nil
          {{:value, ticket}, _} -> ticket
        end

      {{:value, ticket}, _rest_queue} ->
        ticket
    end
  end

  @doc """
  Checks if a rank has queued tickets.
  """
  def rank_present?(state, rank) do
    :gb_sets.is_member(rank, state.non_empty_ranks)
  end

  @doc """
  Returns the set of non-empty ranks for scanning operations.
  """
  def non_empty_ranks(state) do
    state.non_empty_ranks
  end
end
