defmodule QueueOfMatchmaking.Matchmaking.State do
  @moduledoc """
  Pure data structure for partition matchmaking state.
  Manages rank-based queues and provides safe functions for concurrent matching.
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

  @type ticket :: {user_id :: String.t(), rank :: non_neg_integer(), enq_ms :: integer()}
  @type t :: %__MODULE__{
          partition_id: String.t(),
          range_start: non_neg_integer(),
          range_end: non_neg_integer(),
          queues_by_rank: %{non_neg_integer() => :queue.queue()},
          non_empty_ranks: :gb_sets.set(),
          queued_count: non_neg_integer(),
          tick_cursor: :gb_sets.iter() | nil,
          config: map()
        }

  @doc """
  Creates a new partition state.
  """
  @spec new(String.t(), non_neg_integer(), non_neg_integer(), map()) :: t()
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
  Used when a new user is coming in.
  """
  @spec enqueue(t(), ticket()) :: t()
  def enqueue(state, ticket) do
    {_user_id, rank, _enq_ms} = ticket
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
  Used for rollback when opponent removal fails.
  """
  @spec enqueue_front(t(), ticket()) :: t()
  def enqueue_front(state, ticket) do
    {_user_id, rank, _enq_ms} = ticket
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
  Updates other state items to reflect that
  Returns {nil, state} if rank has no queued tickets.
  """
  @spec dequeue_head(t(), non_neg_integer()) :: {ticket() | nil, t()}
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
  Returns {:ok, new_state} on match, {:error, :mismatch} otherwise.
  """
  @spec dequeue_head_if_matches(t(), non_neg_integer(), ticket()) ::
          {:ok, t()} | {:error, :mismatch}
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
  Returns nil if rank has no queued tickets.
  """
  @spec peek_head(t(), non_neg_integer()) :: ticket() | nil
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
  Checks if a rank has queued tickets.
  """
  @spec rank_present?(t(), non_neg_integer()) :: boolean()
  def rank_present?(state, rank) do
    :gb_sets.is_member(rank, state.non_empty_ranks)
  end

  @doc """
  Returns the set of non-empty ranks for scanning operations.
  """
  @spec non_empty_ranks(t()) :: :gb_sets.set()
  def non_empty_ranks(state) do
    state.non_empty_ranks
  end
end
