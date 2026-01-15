import Config

config :queue_of_matchmaking,
  rank_min: 0,
  rank_max: 10_000,
  partition_count: 20,
  user_index_shard_count: 8,
  widening_step_ms: 200,
  widening_step_diff: 25,
  widening_cap: 1000,
  tick_interval_ms: 25,
  max_tick_attempts: 200,
  max_scan_ranks: 50,
  rpc_timeout_ms: 100,
  enqueue_timeout_ms: 100,
  backpressure: [
    message_queue_limit: 2_000,
    queued_count_limit: 50_000
  ]

config :queue_of_matchmaking, QueueOfMatchmaking.Web.Endpoint,
  http: [port: 4000],
  server: true,
  pubsub_server: QueueOfMatchmaking.PubSub

# TODO: batching requests for higher throughput (future enhancement)

import_config "#{config_env()}.exs"
