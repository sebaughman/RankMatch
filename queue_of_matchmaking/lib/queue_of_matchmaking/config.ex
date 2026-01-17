defmodule QueueOfMatchmaking.Config do
  @moduledoc """
  Centralized configuration access for matchmaking system.
  """

  @doc """
  Returns matchmaking configuration as a map.
  """
  def matchmaking_config do
    backpressure = Application.fetch_env!(:queue_of_matchmaking, :backpressure)

    %{
      tick_interval_ms: Application.fetch_env!(:queue_of_matchmaking, :tick_interval_ms),
      max_tick_attempts: Application.fetch_env!(:queue_of_matchmaking, :max_tick_attempts),
      max_scan_ranks: Application.fetch_env!(:queue_of_matchmaking, :max_scan_ranks),
      widening_step_ms: Application.fetch_env!(:queue_of_matchmaking, :widening_step_ms),
      widening_step_diff: Application.fetch_env!(:queue_of_matchmaking, :widening_step_diff),
      widening_cap: Application.fetch_env!(:queue_of_matchmaking, :widening_cap),
      enqueue_timeout_ms: Application.fetch_env!(:queue_of_matchmaking, :enqueue_timeout_ms),
      backpressure: %{
        message_queue_limit: Keyword.fetch!(backpressure, :message_queue_limit),
        queued_count_limit: Keyword.fetch!(backpressure, :queued_count_limit)
      }
    }
  end
end
