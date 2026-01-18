defmodule QueueOfMatchmaking.Matchmaking.Helpers do
  alias QueueOfMatchmaking.Matchmaking.Nearest
  @moduledoc """
  Helper functions for cross-partition matching during tick processing.
  """

  def combine_candidates(local_opponent, adjacent_candidates) do
    local_with_source = if local_opponent, do: [{:local, local_opponent}], else: []
    remote_with_source = Enum.map(adjacent_candidates, fn {pid, t} -> {{:remote, pid}, t} end)

    local_with_source ++ remote_with_source
  end


  def choose_best(requester, all_candidates, best) do
    case choose_best_with_source(requester, all_candidates) do
      nil ->
        best

      {opponent_ticket, source} ->
        diff = abs(elem(opponent_ticket, 1) - elem(requester, 1))
        choose_better_pair(best, {requester, opponent_ticket, source, diff})
    end
  end

  defp choose_best_with_source(_requester, []), do: nil

  defp choose_best_with_source({_req_user, req_rank, _req_enq}, candidates) do
    {source, best_opponent} =
      Enum.min_by(candidates, fn {_source, {opp_user, opp_rank, opp_enq}} ->
        diff = abs(opp_rank - req_rank)
        {diff, opp_enq, opp_rank, opp_user}
      end)

    {best_opponent, source}
  end

  defp choose_better_pair(nil, cand), do: cand

  defp choose_better_pair({_, b_ticket, _, b_diff} = best, {_, c_ticket, _, c_diff} = cand) do
    if Nearest.better?(c_ticket, c_diff, b_ticket, b_diff) do
      cand
    else
      best
    end
  end
end
