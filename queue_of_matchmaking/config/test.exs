import Config

config :queue_of_matchmaking, QueueOfMatchmaking.Web.Endpoint,
  http: [port: 4002],
  server: false

config :queue_of_matchmaking,
  backpressure: [
    message_queue_limit: 100,
    queued_count_limit: 500
  ]
