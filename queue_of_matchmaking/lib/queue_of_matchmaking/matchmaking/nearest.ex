defmodule QueueOfMatchmaking.Matchmaking.Nearest do
  @moduledoc """
  Closest-rank opponent selection with deterministic tie-breaking.
  """

  alias QueueOfMatchmaking.Matchmaking.State

  defmodule ScanCtx do
    defstruct [
      :state,
      :ranks,
      :requester_rank,
      :allowed_diff,
      :exclude_user_id,
      :left_idx,
      :right_idx,
      :max_scan,
      scanned: 0,
      best: nil
    ]
  end

  @doc """
  Finds the best opponent by scanning outward from requester rank.
  """
  def peek_best_opponent(
        state,
        {_uid, requester_rank, _enq},
        allowed_diff,
        exclude_user_id
      ) do
    ranks = :gb_sets.to_list(state.non_empty_ranks)

    case ranks do
      [] ->
        nil

      _ ->
        ranks
        |> new_ctx(state, requester_rank, allowed_diff, exclude_user_id)
        |> same_rank_head()
        |> case do
          {:hit, ticket} ->
            ticket

          {:miss, ctx} ->
            ctx
            |> walk_outward()
            |> best_ticket()
        end
    end
  end

  @doc """
  Atomically removes opponent ticket from state.
  """
  def take_best_opponent(state, {_, rank, _} = opponent_ticket) do
    State.dequeue_head_if_matches(state, rank, opponent_ticket)
  end

  # -- ctx setup --

  defp new_ctx(ranks, state, requester_rank, allowed_diff, exclude_user_id) do
    {left_idx, right_idx} = insertion_window(ranks, requester_rank)

    %ScanCtx{
      state: state,
      ranks: ranks,
      requester_rank: requester_rank,
      allowed_diff: allowed_diff,
      exclude_user_id: exclude_user_id,
      left_idx: left_idx,
      right_idx: right_idx,
      max_scan: state.config.max_scan_ranks
    }
  end

  defp insertion_window(ranks, target) do
    right_idx = lower_bound(ranks, target, 0, length(ranks))
    {right_idx - 1, right_idx}
  end

  defp lower_bound(ranks, target, low, high) when low < high do
    mid = div(low + high, 2)

    if Enum.at(ranks, mid) < target do
      lower_bound(ranks, target, mid + 1, high)
    else
      lower_bound(ranks, target, low, mid)
    end
  end

  defp lower_bound(_ranks, _target, low, _high), do: low

  # -- same-rank early return --

  defp same_rank_head(
         %ScanCtx{ranks: ranks, requester_rank: req, left_idx: li, right_idx: ri} = ctx
       ) do
    case {rank_at(ranks, li), rank_at(ranks, ri)} do
      {^req, _} -> same_rank_try(ctx, req)
      {_, ^req} -> same_rank_try(ctx, req)
      _ -> {:miss, ctx}
    end
  end

  defp same_rank_try(%ScanCtx{} = ctx, rank) do
    case State.peek_head_skipping_user(ctx.state, rank, ctx.exclude_user_id) do
      nil -> {:miss, ctx}
      ticket -> {:hit, ticket}
    end
  end

  # -- main scan loop --

  defp walk_outward(%ScanCtx{scanned: scanned, max_scan: max_scan} = ctx)
       when scanned >= max_scan,
       do: ctx

  defp walk_outward(ctx) do
    case next_step(ctx) do
      :stop -> ctx
      {:cont, ctx2} -> walk_outward(ctx2)
    end
  end

  defp next_step(%ScanCtx{} = ctx) do
    ranks = ctx.ranks
    left_rank = rank_at(ranks, ctx.left_idx)
    right_rank = rank_at(ranks, ctx.right_idx)

    case pick_side(left_rank, right_rank, ctx.requester_rank, ctx.allowed_diff) do
      :stop ->
        :stop

      {:left, rank} ->
        ctx
        |> consider_rank(rank)
        |> bump_left()
        |> then(&{:cont, &1})

      {:right, rank} ->
        ctx
        |> consider_rank(rank)
        |> bump_right()
        |> then(&{:cont, &1})
    end
  end

  defp rank_at(_ranks, idx) when idx < 0, do: nil
  defp rank_at(ranks, idx) when idx >= length(ranks), do: nil
  defp rank_at(ranks, idx), do: Enum.at(ranks, idx)

  defp pick_side(nil, nil, _req_rank, _allowed), do: :stop

  defp pick_side(left, nil, req_rank, allowed) do
    if abs(left - req_rank) <= allowed, do: {:left, left}, else: :stop
  end

  defp pick_side(nil, right, req_rank, allowed) do
    if abs(right - req_rank) <= allowed, do: {:right, right}, else: :stop
  end

  defp pick_side(left, right, req_rank, allowed) do
    left_diff = abs(left - req_rank)
    right_diff = abs(right - req_rank)

    cond do
      left_diff > allowed and right_diff > allowed -> :stop
      left_diff > allowed -> {:right, right}
      right_diff > allowed -> {:left, left}
      left_diff < right_diff -> {:left, left}
      right_diff < left_diff -> {:right, right}
      true -> {:left, left}
    end
  end

  defp bump_left(%ScanCtx{} = ctx),
    do: %{ctx | left_idx: ctx.left_idx - 1, scanned: ctx.scanned + 1}

  defp bump_right(%ScanCtx{} = ctx),
    do: %{ctx | right_idx: ctx.right_idx + 1, scanned: ctx.scanned + 1}

  # -- candidate evaluation / best tracking --

  defp consider_rank(ctx, nil), do: ctx

  defp consider_rank(%ScanCtx{} = ctx, rank) do
    case State.peek_head_skipping_user(ctx.state, rank, ctx.exclude_user_id) do
      nil ->
        ctx

      ticket ->
        diff = abs(rank - ctx.requester_rank)
        %{ctx | best: choose_best(ctx.best, ticket, diff)}
    end
  end

  defp choose_best(nil, ticket, diff), do: {ticket, diff}

  defp choose_best({best_ticket, best_diff} = best, candidate_ticket, candidate_diff) do
    if better?(candidate_ticket, candidate_diff, best_ticket, best_diff) do
      {candidate_ticket, candidate_diff}
    else
      best
    end
  end

  defp better?({c_user, c_rank, c_enq}, c_diff, {b_user, b_rank, b_enq}, b_diff) do
    cond do
      c_diff < b_diff -> true
      c_diff > b_diff -> false
      c_enq < b_enq -> true
      c_enq > b_enq -> false
      c_rank < b_rank -> true
      c_rank > b_rank -> false
      c_user < b_user -> true
      true -> false
    end
  end

  defp best_ticket(%ScanCtx{best: nil}), do: nil
  defp best_ticket(%ScanCtx{best: {ticket, _}}), do: ticket
end
