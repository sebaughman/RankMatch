import Config

config :logger, level: :info

# widening_step_ms:
## How often (in milliseconds) the widening window grows for a waiting ticket. Every widening_step_ms of queue age, the allowed rank difference increases.

# widening_step_diff:
## How much rank difference to add per widening step. Bigger = users can match across larger skill gaps sooner.

# widening_cap:
## The maximum allowed rank difference widening will ever reach. This bounds match looseness and prevents “infinite widening.”

# tick_interval_ms:
## How frequently each PartitionWorker runs its periodic :tick to try widening-based matches. Smaller = more responsive widening, but more CPU work.

# max_tick_attempts:
## The maximum number of match attempts a single tick is allowed to execute before stopping.
## This bounds work per tick so a busy partition can’t get stuck matching forever.

# max_scan_ranks:
## The limit on how many distinct ranks the “nearest opponent” search is allowed to inspect per attempt.
## This prevents widening from turning into an unbounded scan as queues grow.

# rpc_timeout_ms:
## Timeout for cross-partition GenServer RPCs (peek_nearest / reserve). If a neighboring partition is slow/down, calls fail fast and you fall back safely.

# enqueue_timeout_ms:
## Timeout for the resolver → partition enqueue call. It bounds how long the client request will wait before treating the enqueue as failed/overloaded.

# backpressure.message_queue_limit:
## Reject enqueues when the partition process mailbox (message_queue_len) exceeds this threshold. It protects the worker from spiraling latency under overload.

# backpressure.queued_count_limit:
## Reject enqueues when the partition's in-memory queued ticket count exceeds this threshold. It caps memory growth and limits work amplification during heavy load.

# immediate_match_allowed_diff:
## The maximum rank difference allowed for immediate matching on enqueue (before widening).
## Higher values = more immediate matches = higher throughput, but looser match quality.
## Set to 0 for exact-rank-only immediate matching (requires widening for all other matches).

config :queue_of_matchmaking,
  epoch: 1,
  rank_min: 0,
  rank_max: 10_000,
  partition_count: 32,
  user_index_shard_count: 16,

  immediate_match_allowed_diff: 100,

  widening_step_ms: 50,
  widening_step_diff: 150,
  widening_cap: 2_000,

  tick_interval_ms: 100,
  max_tick_attempts: 50,
  max_scan_ranks: 100,

  rpc_timeout_ms: 100,
  enqueue_timeout_ms: 200,
  backpressure: [
    message_queue_limit: 2_500,
    queued_count_limit: 50_000
  ]

config :queue_of_matchmaking, QueueOfMatchmaking.Web.Endpoint,
  http: [port: 4000],
  server: true,
  pubsub_server: QueueOfMatchmaking.PubSub

# TODO: batching requests for higher throughput (future enhancement)

import_config "#{config_env()}.exs"
