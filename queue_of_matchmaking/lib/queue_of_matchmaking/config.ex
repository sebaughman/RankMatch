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
      immediate_match_allowed_diff: Application.fetch_env!(:queue_of_matchmaking, :immediate_match_allowed_diff),
      backpressure: %{
        message_queue_limit: Keyword.fetch!(backpressure, :message_queue_limit),
        queued_count_limit: Keyword.fetch!(backpressure, :queued_count_limit)
      }
    }
  end

  @doc """
  Returns cluster configuration as a keyword list.
  Used for partition assignment and cluster topology.
  """
  def cluster_config do
    [
      epoch: Application.fetch_env!(:queue_of_matchmaking, :epoch),
      rank_min: Application.fetch_env!(:queue_of_matchmaking, :rank_min),
      rank_max: Application.fetch_env!(:queue_of_matchmaking, :rank_max),
      partition_count: Application.fetch_env!(:queue_of_matchmaking, :partition_count)
    ]
  end

  @doc """
  Returns the number of user index shards.
  """
  def user_index_shard_count do
    Application.fetch_env!(:queue_of_matchmaking, :user_index_shard_count)
  end

  @doc """
  Returns the enqueue timeout in milliseconds.
  """
  def enqueue_timeout_ms do
    Application.fetch_env!(:queue_of_matchmaking, :enqueue_timeout_ms)
  end

  @doc """
  Returns the RPC timeout in milliseconds for cross-partition calls.
  """
  def rpc_timeout_ms do
    Application.fetch_env!(:queue_of_matchmaking, :rpc_timeout_ms)
  end
end
